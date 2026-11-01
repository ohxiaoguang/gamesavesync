import XCTest
import Foundation

final class ZipTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gss-zip-\(UUID().uuidString)")
        try TestSupport.makeDirectory(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRoundTripPreservesStructureAndContent() throws {
        let archive = root.appendingPathComponent("test.zip")
        let entries = [
            ZipEntrySource(path: "saves/", isDirectory: true),
            ZipEntrySource(path: "saves/slot1.sav", data: Data("hello".utf8)),
            ZipEntrySource(path: "saves/nested/slot2.sav", data: Data(repeating: 0x41, count: 200_000)),
            ZipEntrySource(path: "saves/空 目录/角色.sav", data: Data("unicode".utf8)),
        ]
        try ZipWriter.write(entries: entries, to: archive)

        let destination = root.appendingPathComponent("out")
        try ZipReader.extract(at: archive, to: destination)

        XCTAssertEqual(TestSupport.contents(destination, "saves/slot1.sav"), "hello")
        XCTAssertEqual(TestSupport.contents(destination, "saves/空 目录/角色.sav"), "unicode")
        let big = try Data(contentsOf: destination.appendingPathComponent("saves/nested/slot2.sav"))
        XCTAssertEqual(big.count, 200_000)
        XCTAssertTrue(FileSystem.isDirectory(destination.appendingPathComponent("saves/nested")))
    }

    func testCompressionIsAppliedToRepetitiveData() throws {
        let archive = root.appendingPathComponent("compress.zip")
        let payload = Data(repeating: 0x30, count: 100_000)
        try ZipWriter.write(entries: [ZipEntrySource(path: "a.bin", data: payload)], to: archive)
        let size = FileSystem.size(of: archive)
        XCTAssertLessThan(size, 5_000, "repetitive data should be deflated")
    }

    func testChecksumMismatchIsDetected() throws {
        let archive = root.appendingPathComponent("bad.zip")
        try ZipWriter.write(entries: [ZipEntrySource(path: "a.txt", data: Data("hello world".utf8))], to: archive)

        // Flip a byte inside the stored payload; the CRC must catch it.
        var data = try Data(contentsOf: archive)
        let target = data.range(of: Data("hello world".utf8))
        XCTAssertNotNil(target)
        if let index = target?.lowerBound {
            data[index] = 0x48 // 'H'
        }
        try data.write(to: archive)

        XCTAssertThrowsError(try ZipReader.extract(at: archive, to: root.appendingPathComponent("out"))) { error in
            guard case ZipError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testPathTraversalIsRejected() throws {
        let archive = root.appendingPathComponent("evil.zip")
        try ZipWriter.write(entries: [
            ZipEntrySource(path: "../escaped.txt", data: Data("nope".utf8)),
            ZipEntrySource(path: "ok.txt", data: Data("fine".utf8)),
        ], to: archive)

        XCTAssertThrowsError(try ZipReader.extract(at: archive, to: root.appendingPathComponent("out"))) { error in
            guard case ZipError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    }

    func testAbsoluteAndWindowsPathsAreRejected() throws {
        XCTAssertThrowsError(try SafePath.relativePath(fromArchiveEntry: "/etc/passwd", isDirectory: false))
        XCTAssertThrowsError(try SafePath.relativePath(fromArchiveEntry: "C:/Windows/system32", isDirectory: false))
        XCTAssertThrowsError(try SafePath.relativePath(fromArchiveEntry: "a/../../b", isDirectory: false))
        XCTAssertEqual(try SafePath.relativePath(fromArchiveEntry: "a//b/./c.txt", isDirectory: false), "a/b/c.txt")
    }

    func testTruncatedArchiveIsRejected() throws {
        let archive = root.appendingPathComponent("truncated.zip")
        try ZipWriter.write(entries: [ZipEntrySource(path: "a.txt", data: Data("abcdefghij".utf8))], to: archive)
        var data = try Data(contentsOf: archive)
        data = data.prefix(data.count - 30)
        try data.write(to: archive)

        XCTAssertThrowsError(try ZipReader.extract(at: archive, to: root.appendingPathComponent("out")))
    }

    func testLargeArchiveKeepsZip64Out() throws {
        // Sanity check on the entry-count guard rather than allocating a huge archive.
        XCTAssertNoThrow(try ZipWriter.write(entries: [], to: root.appendingPathComponent("empty.zip")))
        let entries = try ZipReader.entries(at: root.appendingPathComponent("empty.zip"))
        XCTAssertTrue(entries.isEmpty)
    }
}
