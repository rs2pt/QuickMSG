import Foundation

/// A parsed Outlook .msg message (MS-OXMSG), reduced to what a preview needs.
struct MSGMessage {
    struct Recipient {
        enum Kind { case to, cc, bcc }
        var name: String
        var address: String
        var kind: Kind
    }

    struct Attachment {
        var fileName: String
        var mimeType: String?
        var contentID: String?
        var data: Data?          // nil for embedded messages / unreadable data
        var size: Int
        var isInline: Bool
    }

    var subject = ""
    var senderName = ""
    var senderAddress = ""
    var date: Date?
    var recipients: [Recipient] = []
    var attachments: [Attachment] = []
    var plainBody: String?
    var htmlBody: String?
    var rtfBody: Data?          // decompressed RTF
}

enum MSGParser {

    enum Failure: Error { case notMSG }

    static func parse(_ data: Data) throws -> MSGMessage {
        let cfb: CFBReader
        do { cfb = try CFBReader(data: data) } catch { throw Failure.notMSG }
        return parse(storage: cfb.root, in: cfb, topLevel: true)
    }

    // MARK: Message / sub-objects

    private static func parse(storage: Int, in cfb: CFBReader, topLevel: Bool) -> MSGMessage {
        var msg = MSGMessage()
        let props = PropertyBag(cfb: cfb, storage: storage, headerSize: topLevel ? 32 : 24)

        msg.subject = props.string(0x0037) ?? props.string(0x0070) ?? ""
        msg.senderName = props.string(0x0C1A) ?? props.string(0x0042) ?? ""
        let smtp = props.string(0x5D01) ?? props.string(0x5D02)
        let raw = props.string(0x0C1F) ?? props.string(0x0065)
        msg.senderAddress = smtp ?? (raw?.contains("@") == true ? raw! : "")
        msg.date = props.date(0x0039) ?? props.date(0x0E06)

        msg.plainBody = props.string(0x1000)
        if let html = props.binary(0x1013) {
            msg.htmlBody = decodeHTML(html, codepage: props.int32(0x3FDE) ?? props.int32(0x3FFD))
        } else if let html = props.string(0x1013) {
            msg.htmlBody = html
        }
        if let rtf = props.binary(0x1009) { msg.rtfBody = RTFDecompressor.decompress(rtf) }

        for id in cfb.children(of: storage) {
            let name = cfb.entries[id].name
            if name.hasPrefix("__recip_version1.0_#") {
                msg.recipients.append(recipient(storage: id, in: cfb))
            } else if name.hasPrefix("__attach_version1.0_#") {
                msg.attachments.append(attachment(storage: id, in: cfb))
            }
        }
        return msg
    }

    private static func recipient(storage: Int, in cfb: CFBReader) -> MSGMessage.Recipient {
        let props = PropertyBag(cfb: cfb, storage: storage, headerSize: 8)
        let name = props.string(0x3001) ?? ""
        let smtp = props.string(0x39FE)
        let raw = props.string(0x3003)
        let address = smtp ?? (raw?.contains("@") == true ? raw! : "")
        let kind: MSGMessage.Recipient.Kind
        switch props.int32(0x0C15) {
        case 2: kind = .cc
        case 3: kind = .bcc
        default: kind = .to
        }
        return .init(name: name, address: address, kind: kind)
    }

    private static func attachment(storage: Int, in cfb: CFBReader) -> MSGMessage.Attachment {
        let props = PropertyBag(cfb: cfb, storage: storage, headerSize: 8)
        let fileName = props.string(0x3707) ?? props.string(0x3704) ?? props.string(0x3001) ?? "(sem nome)"
        let flags = props.int32(0x3714) ?? 0
        let contentID = props.string(0x3712)
        let data = props.binary(0x3701)
        // Embedded .msg attachments are sub-storages (type 0x000D); show them by name only.
        let embedded = cfb.child(of: storage, named: "__substg1.0_3701000D") != nil
        return .init(fileName: fileName,
                     mimeType: props.string(0x370E),
                     contentID: contentID,
                     data: embedded ? nil : data,
                     size: data?.count ?? 0,
                     isInline: (flags & 0x4) != 0 && contentID != nil)
    }

    // MARK: HTML decoding

    private static func decodeHTML(_ data: Data, codepage: Int32?) -> String {
        if let cp = codepage, let enc = encoding(forCodepage: cp),
           let s = String(data: data, encoding: enc) { return s }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    static func encoding(forCodepage cp: Int32) -> String.Encoding? {
        if cp == 65001 { return .utf8 }
        if cp == 1252 { return .windowsCP1252 }
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(cp))
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

/// Reads the `__substg1.0_XXXXYYYY` streams and the fixed-size
/// `__properties_version1.0` table of one storage.
private struct PropertyBag {
    let cfb: CFBReader
    let storage: Int
    private var fixed: [UInt16: Data] = [:]   // property id -> 8-byte value cell
    private var codepage: Int32 = 1252

    init(cfb: CFBReader, storage: Int, headerSize: Int) {
        self.cfb = cfb
        self.storage = storage
        if let id = cfb.child(of: storage, named: "__properties_version1.0"),
           let table = cfb.stream(id) {
            var o = headerSize
            while o + 16 <= table.count {
                let type = table.u16(o), pid = table.u16(o + 2)
                fixed[pid] = Data([type & 0xFF, type >> 8].map(UInt8.init(truncatingIfNeeded:)))
                    + table.subdata(in: (table.startIndex + o + 8)..<(table.startIndex + o + 16))
                o += 16
            }
        }
        if let cp = int32(0x3FFD), cp > 0 { codepage = cp }
    }

    private func streamData(_ pid: UInt16, type: UInt16) -> Data? {
        let name = String(format: "__substg1.0_%04X%04X", pid, type)
        return cfb.child(of: storage, named: name).flatMap { cfb.stream($0) }
    }

    func string(_ pid: UInt16) -> String? {
        if let d = streamData(pid, type: 0x001F) {
            return String(data: d, encoding: .utf16LittleEndian)?.trimmingCharacters(in: .controlCharacters)
        }
        if let d = streamData(pid, type: 0x001E) {
            let enc = MSGParser.encoding(forCodepage: codepage) ?? .windowsCP1252
            return (String(data: d, encoding: enc) ?? String(decoding: d, as: UTF8.self))
                .trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    func binary(_ pid: UInt16) -> Data? { streamData(pid, type: 0x0102) }

    func int32(_ pid: UInt16) -> Int32? {
        guard let cell = fixed[pid], cell.u16(0) == 0x0003 else { return nil }
        return Int32(bitPattern: cell.u32(2))
    }

    func date(_ pid: UInt16) -> Date? {
        guard let cell = fixed[pid], cell.u16(0) == 0x0040 else { return nil }
        let filetime = cell.u64(2)                       // 100 ns ticks since 1601-01-01
        guard filetime > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(filetime) / 10_000_000 - 11_644_473_600)
    }
}
