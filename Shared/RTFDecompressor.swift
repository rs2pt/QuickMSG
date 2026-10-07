import Foundation

/// Decompresses the "compressed RTF" stream of a .msg (MS-OXRTFCP, LZFu).
enum RTFDecompressor {

    private static let prebuilt: [UInt8] = Array((
        "{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript "
        + "\\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par "
        + "\\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx"
    ).utf8)

    private static let maxOutput = 64 << 20

    static func decompress(_ input: Data) -> Data? {
        guard input.count >= 16 else { return nil }
        // LZFu expands at most ~4096/2 bytes per input byte pair; cap well below the 4 GB a header can claim.
        let rawSize = min(Int(input.u32(4)), maxOutput)
        let type = input.u32(8)
        let body = 16

        if type == 0x414C454D { // "MELA": stored uncompressed
            return input.subdata(in: input.startIndex + body ..< min(input.endIndex, input.startIndex + body + rawSize))
        }
        guard type == 0x75465A4C else { return nil } // "LZFu"

        var dict = [UInt8](repeating: 0x20, count: 4096)
        dict.replaceSubrange(0..<prebuilt.count, with: prebuilt)
        var writePos = prebuilt.count
        var out = [UInt8]()
        out.reserveCapacity(min(rawSize, input.count * 8))

        let bytes = [UInt8](input)
        var i = body
        decoding: while i < bytes.count, out.count < rawSize {
            let control = bytes[i]; i += 1
            for bit in 0..<8 {
                if out.count >= rawSize { break decoding }
                if control & (1 << bit) != 0 {
                    guard i + 1 < bytes.count else { break decoding }
                    let hi = Int(bytes[i]), lo = Int(bytes[i + 1]); i += 2
                    let offset = (hi << 4) | (lo >> 4)
                    let length = (lo & 0x0F) + 2
                    if offset == writePos % 4096 { break decoding } // end marker
                    var read = offset
                    for _ in 0..<length {
                        let b = dict[read % 4096]
                        read += 1
                        out.append(b)
                        dict[writePos % 4096] = b
                        writePos += 1
                    }
                } else {
                    guard i < bytes.count else { break decoding }
                    let b = bytes[i]; i += 1
                    out.append(b)
                    dict[writePos % 4096] = b
                    writePos += 1
                }
            }
        }
        return Data(out)
    }
}
