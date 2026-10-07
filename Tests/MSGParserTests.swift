import XCTest

final class MSGParserTests: XCTestCase {

    func testRejectsNonCFBData() {
        XCTAssertThrowsError(try MSGParser.parse(Data("not a msg file".utf8)))
    }

    func testStoredRTFIsReturnedVerbatim() {
        // "MELA" marks an uncompressed stream; LZFu is exercised by the examples/ test below.
        let stored = Data([0, 0, 0, 0, 5, 0, 0, 0, 0x4D, 0x45, 0x4C, 0x41, 0, 0, 0, 0] + Array("hello".utf8))
        XCTAssertEqual(RTFDecompressor.decompress(stored).map { String(decoding: $0, as: UTF8.self) }, "hello")
    }

    /// Real messages live in examples/ (git-ignored); skipped when absent.
    func testParsesLocalExamples() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "msg" } ?? []
        try XCTSkipIf(files.isEmpty, "no examples/*.msg")
        for f in files {
            let m = try MSGParser.parse(Data(contentsOf: f))
            XCTAssertFalse(m.subject.isEmpty, f.lastPathComponent)
        }
    }
}
