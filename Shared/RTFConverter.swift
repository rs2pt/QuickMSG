import Foundation

/// Reads the RTF body of a .msg. Outlook usually stores HTML mail as RTF with
/// the original HTML encapsulated inside (MS-OXRTFEX); that is recovered as
/// HTML. Anything else is flattened to plain text.
enum RTFConverter {

    enum Result {
        case html(String)
        case text(String)
    }

    static func convert(_ rtf: Data) -> Result {
        let bytes = [UInt8](rtf)
        let fromHTML = String(decoding: bytes.prefix(2048), as: UTF8.self).contains("\\fromhtml")
        let out = scan(bytes, htmlMode: fromHTML)
        return fromHTML ? .html(out) : .text(out)
    }

    private struct Group {
        var skip = false        // destination we don't render (fonttbl, colortbl, ...)
        var htmlTag = false     // {\*\htmltagN ...}: original HTML source
        var suppress = false    // after \htmlrtf: RTF-only rendering of the HTML
    }

    private static let skippedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header", "footer",
        "generator", "listtable", "listoverridetable", "revtbl", "rsidtbl", "latentstyles",
        "themedata", "datastore", "colorschememapping", "mmathPr",
    ]

    private static func scan(_ b: [UInt8], htmlMode: Bool) -> String {
        var out = String.UnicodeScalarView()
        var stack: [Group] = []
        var g = Group()
        var codepage: Int32 = 1252
        var unicodeSkip = 1
        var pendingSkip = 0          // bytes to drop after \uN
        var i = 0
        var atGroupStart = false     // directly after '{'
        var starred = false          // saw {\* ...

        func emit(_ s: Unicode.Scalar) {
            guard !g.skip, g.htmlTag || !g.suppress || !htmlMode else { return }
            out.append(s)
        }
        func emitText(_ s: String) { s.unicodeScalars.forEach(emit) }

        while i < b.count {
            let c = b[i]
            switch c {
            case UInt8(ascii: "{"):
                stack.append(g)
                atGroupStart = true; starred = false
                i += 1
            case UInt8(ascii: "}"):
                if let top = stack.popLast() { g = top }
                atGroupStart = false
                i += 1
            case UInt8(ascii: "\\"):
                i += 1
                guard i < b.count else { break }
                let n = b[i]
                if n == UInt8(ascii: "*") {
                    starred = true; i += 1
                    continue
                }
                if n == UInt8(ascii: "'") {
                    let hex = i + 2 < b.count ? String(decoding: b[(i + 1)...(i + 2)], as: UTF8.self) : ""
                    i += 3
                    if pendingSkip > 0 { pendingSkip -= 1; continue }
                    if let v = UInt8(hex, radix: 16) {
                        let enc = MSGParser.encoding(forCodepage: codepage) ?? .windowsCP1252
                        if let s = String(data: Data([v]), encoding: enc) { emitText(s) }
                    }
                    continue
                }
                if !(n >= 0x41 && n <= 0x5A) && !(n >= 0x61 && n <= 0x7A) {
                    // control symbol: \\ \{ \} \~ \- \_ ...
                    i += 1
                    switch n {
                    case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"): emit(Unicode.Scalar(n))
                    case UInt8(ascii: "~"): emit("\u{00A0}")
                    default: break
                    }
                    continue
                }
                // control word
                var j = i
                while j < b.count, (b[j] >= 0x41 && b[j] <= 0x5A) || (b[j] >= 0x61 && b[j] <= 0x7A) { j += 1 }
                let word = String(decoding: b[i..<j], as: UTF8.self)
                var sign = 1
                if j < b.count, b[j] == UInt8(ascii: "-") { sign = -1; j += 1 }
                var num: Int?
                while j < b.count, b[j] >= 0x30 && b[j] <= 0x39 {
                    num = min((num ?? 0) * 10 + Int(b[j] - 0x30), 1_000_000_000)   // clamp: no overflow trap
                    j += 1
                }
                if j < b.count, b[j] == UInt8(ascii: " ") { j += 1 }
                i = j
                let value = num.map { $0 * sign }

                if atGroupStart {
                    if starred {
                        if word == "htmltag" { g.htmlTag = true } else if !word.hasPrefix("html") { g.skip = true }
                    } else if skippedDestinations.contains(word) {
                        g.skip = true
                    }
                    atGroupStart = false
                }
                switch word {
                case "ansicpg": if let v = value, v > 0, v < 100_000 { codepage = Int32(v) }
                case "uc": unicodeSkip = max(0, min(value ?? 1, 16))
                case "htmlrtf": g.suppress = (value ?? 1) != 0
                case "par", "line": if !htmlMode { emit("\n") }
                case "tab": emit("\t")
                case "emdash": emit("\u{2014}")
                case "endash": emit("\u{2013}")
                case "bullet": emit("\u{2022}")
                case "u":
                    if var v = value {
                        if v < 0 { v += 65536 }
                        if v >= 0, let s = Unicode.Scalar(UInt32(v)) { emit(s) }
                        pendingSkip = unicodeSkip
                    }
                default: break
                }
                starred = false
            case 0x0D, 0x0A:
                i += 1
            default:
                atGroupStart = false
                i += 1
                if pendingSkip > 0 { pendingSkip -= 1; continue }
                // Bytes outside \'hh are in the document code page too.
                if c < 0x80 { emit(Unicode.Scalar(c)) }
                else if let s = String(data: Data([c]), encoding: MSGParser.encoding(forCodepage: codepage) ?? .windowsCP1252) { emitText(s) }
            }
        }
        return String(out)
    }
}
