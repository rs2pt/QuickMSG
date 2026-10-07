import Foundation

/// Minimal reader for the Compound File Binary format (MS-CFB), the OLE
/// container that .msg files are built on. Read-only, fully in memory.
struct CFBReader {

    enum Failure: Error { case notCFB, corrupt }

    struct Entry {
        enum Kind { case storage, stream, root, other }
        let name: String
        let kind: Kind
        let startSector: UInt32
        let size: UInt64
        var children: [Int] = []
    }

    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private(set) var entries: [Entry] = []
    private var miniStream = Data()

    private static let endOfChain: UInt32 = 0xFFFFFFFE
    private static let freeSect: UInt32 = 0xFFFFFFFF
    private static let noStream: UInt32 = 0xFFFFFFFF

    var root: Int { 0 }

    init(data: Data) throws {
        self.data = data
        guard data.count >= 512,
              data.prefix(8).elementsEqual([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        else { throw Failure.notCFB }

        let sectorShift = Int(data.u16(0x1E))
        let miniShift = Int(data.u16(0x20))
        guard (sectorShift == 9 || sectorShift == 12), miniShift < sectorShift else { throw Failure.corrupt }
        sectorSize = 1 << sectorShift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(data.u32(0x38))

        let fatSectorCount = Int(data.u32(0x2C))
        let firstDirSector = data.u32(0x30)
        let firstMiniFatSector = data.u32(0x3C)
        let miniFatSectorCount = Int(data.u32(0x40))
        var difatSector = data.u32(0x44)
        let difatSectorCount = Int(data.u32(0x48))

        // DIFAT: first 109 entries live in the header, the rest in chained sectors.
        var fatSectors: [UInt32] = []
        for i in 0..<109 {
            let s = data.u32(0x4C + i * 4)
            if s != Self.freeSect { fatSectors.append(s) }
        }
        var guardCount = 0
        while difatSector != Self.endOfChain, difatSector != Self.freeSect, guardCount < difatSectorCount {
            guard let base = offset(of: difatSector) else { throw Failure.corrupt }
            let perSector = sectorSize / 4 - 1
            for i in 0..<perSector {
                let s = data.u32(base + i * 4)
                if s != Self.freeSect { fatSectors.append(s) }
            }
            difatSector = data.u32(base + perSector * 4)
            guardCount += 1
        }
        fatSectors = Array(fatSectors.prefix(fatSectorCount))

        for s in fatSectors {
            guard let base = offset(of: s) else { throw Failure.corrupt }
            for i in 0..<(sectorSize / 4) { fat.append(data.u32(base + i * 4)) }
        }

        // Directory.
        let dirBytes = try chainBytes(start: firstDirSector, limit: nil)
        var parsed: [Entry] = []
        var tree: [(left: UInt32, right: UInt32, child: UInt32)] = []
        for i in 0..<(dirBytes.count / 128) {
            let b = i * 128
            let nameLen = min(Int(dirBytes.u16(b + 0x40)), 64)
            let nameBytes = dirBytes.subdata(in: b..<(b + max(nameLen - 2, 0)))
            let name = String(data: nameBytes, encoding: .utf16LittleEndian) ?? ""
            let kind: Entry.Kind
            switch dirBytes[b + 0x42] {
            case 1: kind = .storage
            case 2: kind = .stream
            case 5: kind = .root
            default: kind = .other
            }
            parsed.append(Entry(name: name, kind: kind,
                                startSector: dirBytes.u32(b + 0x74),
                                size: dirBytes.u64(b + 0x78)))
            tree.append((dirBytes.u32(b + 0x44), dirBytes.u32(b + 0x48), dirBytes.u32(b + 0x4C)))
        }
        guard !parsed.isEmpty else { throw Failure.corrupt }

        // Children of a storage form a red-black tree; an in-order walk lists them.
        func collect(_ id: UInt32, into out: inout [Int], depth: Int = 0) {
            guard id != Self.noStream, Int(id) < parsed.count, depth < 4096 else { return }
            collect(tree[Int(id)].left, into: &out, depth: depth + 1)
            out.append(Int(id))
            collect(tree[Int(id)].right, into: &out, depth: depth + 1)
        }
        for i in 0..<parsed.count where parsed[i].kind == .storage || parsed[i].kind == .root {
            var kids: [Int] = []
            collect(tree[i].child, into: &kids)
            parsed[i].children = kids
        }
        entries = parsed

        // Mini FAT and mini stream.
        if miniFatSectorCount > 0, firstMiniFatSector != Self.endOfChain {
            let bytes = try chainBytes(start: firstMiniFatSector, limit: nil)
            for i in 0..<(bytes.count / 4) { miniFat.append(bytes.u32(i * 4)) }
        }
        if entries[0].startSector != Self.endOfChain {
            miniStream = try chainBytes(start: entries[0].startSector, limit: Int(entries[0].size))
        }
    }

    // MARK: Lookup

    func child(of parent: Int, named name: String) -> Int? {
        entries[parent].children.first { entries[$0].name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func children(of parent: Int) -> [Int] { entries[parent].children }

    /// Bytes of a stream entry.
    func stream(_ id: Int) -> Data? {
        guard entries.indices.contains(id), entries[id].kind == .stream else { return nil }
        let size = Int(clamping: entries[id].size)
        if size < miniCutoff {
            return try? miniChainBytes(start: entries[id].startSector, size: size)
        }
        return try? chainBytes(start: entries[id].startSector, limit: size)
    }

    // MARK: Chains

    private func offset(of sector: UInt32) -> Int? {
        guard sector < 0xFFFFFFFA else { return nil }
        let off = (Int(sector) + 1) * sectorSize
        return off + sectorSize <= data.count ? off : nil
    }

    private func chainBytes(start: UInt32, limit: Int?) throws -> Data {
        var out = Data()
        var s = start
        var hops = 0
        while s != Self.endOfChain {
            guard let off = offset(of: s), hops <= fat.count else { throw Failure.corrupt }
            out.append(data.subdata(in: off..<(off + sectorSize)))
            if let limit, out.count >= limit { break }
            guard Int(s) < fat.count else { throw Failure.corrupt }
            s = fat[Int(s)]
            hops += 1
        }
        if let limit, out.count > limit { out = out.prefix(limit) }
        return out
    }

    private func miniChainBytes(start: UInt32, size: Int) throws -> Data {
        var out = Data()
        var s = start
        var hops = 0
        while s != Self.endOfChain, out.count < size {
            let off = Int(s) * miniSectorSize
            guard off + miniSectorSize <= miniStream.count, hops <= miniFat.count else { throw Failure.corrupt }
            out.append(miniStream.subdata(in: off..<(off + miniSectorSize)))
            guard Int(s) < miniFat.count else { throw Failure.corrupt }
            s = miniFat[Int(s)]
            hops += 1
        }
        return out.prefix(size)
    }
}

extension Data {
    // Data slices keep their parent's indices, so offset from startIndex.
    func u16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= count else { return 0 }
        return UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8
    }

    func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(self[startIndex + o + i]) << (8 * UInt32(i)) }
        return v
    }

    func u64(_ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[startIndex + o + i]) << (8 * UInt64(i)) }
        return v
    }
}
