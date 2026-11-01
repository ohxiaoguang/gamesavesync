import XCTest
import Foundation

/// Covers save folders whose file names contain characters a naive ZIP path check would treat as
/// dangerous. A game written for Windows creates `\savedata0.bin` on a POSIX file system, and the
/// archive has to survive the round trip with the exact same name, without weakening validation.
final class ArchivePathTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gss-archive-\(UUID().uuidString)")
        try TestSupport.makeDirectory(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var stamp: Date { TestSupport.date("2026-11-01T10:00:00.000Z") }

    /// Runs the production chain: scan a real folder, archive it, extract it, verify the result.
    @discardableResult
    private func roundTrip(_ files: [String: String],
                           gameId: String = "test-game") throws -> (scan: ScanResult, extracted: URL) {
        let saves = root.appendingPathComponent("saves")
        try TestSupport.makeDirectory(saves)
        for (path, contents) in files {
            try TestSupport.write(saves, path, contents, modified: stamp)
        }

        let scan = try SaveScanner().scan(directory: saves, computeHash: true)
        let zip = root.appendingPathComponent("save.zip")
        let metadata = try ArchiveManager.createArchive(from: scan,
                                                        to: zip,
                                                        gameId: gameId,
                                                        saveModifiedAt: scan.snapshot.newestModified)
        XCTAssertEqual(metadata.contentHash, scan.snapshot.contentHash)

        let entries = try ZipReader.entries(at: zip)
        XCTAssertEqual(try ZipReader.comment(at: zip), ZipMarker.escapedPaths,
                       "an escaped archive must declare its path encoding")
        for entry in entries where entry.path != SavePathFilter.archiveMetadataName {
            XCTAssertFalse(entry.path.contains("\\"), "archive entry names must stay separator-free: \(entry.path)")
            XCTAssertNoThrow(try SafePath.relativePath(fromArchiveEntry: entry.path, isDirectory: entry.isDirectory),
                             "the entry name must pass the archive path check: \(entry.path)")
        }

        let extracted = root.appendingPathComponent("out")
        let restored = try ArchiveManager.extract(zipURL: zip, to: extracted)
        XCTAssertEqual(restored?.contentHash, scan.snapshot.contentHash)
        return (scan, extracted)
    }

    private func assertIdentical(_ scan: ScanResult, _ extracted: URL,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(TestSupport.relativeFileList(extracted),
                       scan.files.map(\.relativePath).sorted(),
                       "file names must be restored exactly",
                       file: file, line: line)
        for expected in scan.files {
            let restored = extracted.appendingPathComponent(expected.relativePath)
            XCTAssertEqual(try Hashing.sha256Hex(fileAt: restored),
                           try Hashing.sha256Hex(fileAt: expected.url),
                           "content of \(expected.relativePath) must be identical",
                           file: file, line: line)
        }
    }

    // MARK: - Ordinary names

    func testOrdinaryFileNameSurvivesTheRoundTrip() throws {
        let (scan, extracted) = try roundTrip(["savedata0.bin": "slot zero"])
        try assertIdentical(scan, extracted)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("savedata0.bin"), encoding: .utf8),
                       "slot zero")
    }

    // MARK: - Backslashes

    func testLeadingBackslashFileNameSurvivesTheRoundTrip() throws {
        let (scan, extracted) = try roundTrip(["\\savedata0.bin": "leading escape"])
        XCTAssertEqual(scan.files.map(\.relativePath), ["\\savedata0.bin"])
        try assertIdentical(scan, extracted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("\\savedata0.bin").path))
    }

    func testBackslashInsideAFileNameSurvivesTheRoundTrip() throws {
        let (scan, extracted) = try roundTrip(["slot\\1.sav": "middle escape",
                                               "back\\slash\\twice.bin": "two of them"])
        try assertIdentical(scan, extracted)
    }

    func testBackslashInADirectoryNameSurvivesTheRoundTrip() throws {
        let (scan, extracted) = try roundTrip(["bin\\x/slot.sav": "directory escape"])
        try assertIdentical(scan, extracted)
        XCTAssertTrue(FileSystem.isDirectory(extracted.appendingPathComponent("bin\\x")))
    }

    // MARK: - Structure, unicode, percent

    func testNestedDirectoriesSurviveTheRoundTrip() throws {
        let (scan, extracted) = try roundTrip([
            "slot1.sav": "one",
            "profile/options.ini": "two",
            "profile/characters/01/hero.sav": "three",
            "profile/characters/01/gear\\list.sav": "four",
        ])
        try assertIdentical(scan, extracted)
        XCTAssertTrue(FileSystem.isDirectory(extracted.appendingPathComponent("profile/characters/01")))
    }

    func testUnicodeSpacesAndSymbolsSurviveTheRoundTrip() throws {
        let (scan, extracted) = try roundTrip([
            "存档 一.sav": "unicode",
            "my save (1) [hard].sav": "symbols",
            "角色/背景 音乐 #2.bin": "nested unicode",
            "emoji 🎮.sav": "emoji",
        ])
        try assertIdentical(scan, extracted)
    }

    func testPercentIsNotMistakenForAnEscape() throws {
        let (scan, extracted) = try roundTrip([
            "100% done.sav": "plain percent",
            "%5Csavedata.bin": "looks like an escape",
            "%25literal.bin": "looks like another escape",
            "mix\\%5C%.bin": "both characters",
        ])
        try assertIdentical(scan, extracted)
        XCTAssertEqual(ArchivePath.decode("%255C"), "%5C")
        XCTAssertEqual(ArchivePath.decode("100%25"), "100%")
    }

    func testCodecIsReversibleForEveryCombination() {
        let names = ["plain.sav", "\\lead.sav", "mid\\dle.sav", "trail\\.sav", "%", "%5C", "%25",
                     "\\%", "%\\", "%%5C%25\\", "a/\\b/c%25d"]
        for name in names {
            XCTAssertEqual(ArchivePath.decode(ArchivePath.encode(name)), name)
            XCTAssertFalse(ArchivePath.encode(name).contains("\\"), "encoded name keeps no backslash: \(name)")
        }
        XCTAssertEqual(ArchivePath.encode("profile/slot\\1.sav"), "profile/slot%5C1.sav")
    }

    // MARK: - Verification chain

    func testVerifyExtractedFolderAcceptsBackslashNames() throws {
        let (scan, extracted) = try roundTrip(["\\savedata0.bin": "verify me",
                                               "sub\\dir/other.bin": "and me"])
        let verified = try ArchiveManager.verifyExtractedFolder(extracted,
                                                                expectedHash: scan.snapshot.contentHash,
                                                                expectedFileCount: scan.snapshot.fileCount)
        XCTAssertEqual(verified.contentHash, scan.snapshot.contentHash)
        XCTAssertEqual(verified.fileCount, 2)
    }

    // MARK: - Unsafe names stay unsafe

    func testRawBackslashEntriesFromForeignArchivesAreStillRejected() throws {
        let archive = root.appendingPathComponent("foreign.zip")
        try ZipWriter.write(entries: [
            ZipEntrySource(path: "..\\..\\escaped.txt", data: Data("nope".utf8)),
        ], to: archive)

        XCTAssertThrowsError(try ZipReader.extract(at: archive, to: root.appendingPathComponent("out"))) { error in
            guard case ZipError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    }

    func testTraversalAndAbsoluteNamesAreStillRejected() {
        let rejected = [
            "../escaped.txt",
            "a/../../escaped.txt",
            "/etc/passwd",
            "//server/share/escaped.txt",
            "C:/Windows/system32/evil.dll",
            "C:\\Windows\\system32\\evil.dll",
            "\\\\server\\share\\escaped.txt",
            "\\\\?\\C:\\escaped.txt",
            "..",
            "a/..",
            ".",
            "a/\0/b",
            "",
        ]
        for name in rejected {
            XCTAssertThrowsError(try SafePath.relativePath(fromArchiveEntry: name, isDirectory: false),
                                 "must reject \(name)") { error in
                guard case ZipError.unsafePath = error else {
                    return XCTFail("expected unsafePath for \(name), got \(error)")
                }
            }
        }
    }

    func testEscapedNameStillCannotEscapeTheDestination() throws {
        // A hostile archive can spell the traversal with escapes; the decoded name is a plain file
        // name on a POSIX file system, and the final target check keeps it inside the folder.
        let archive = root.appendingPathComponent("escaped-traversal.zip")
        try ZipWriter.write(entries: [
            ZipEntrySource(path: "..%5C..%5Cescaped.txt", data: Data("nope".utf8)),
        ], to: archive, comment: ZipMarker.escapedPaths)

        let out = root.appendingPathComponent("out")
        try ZipReader.extract(at: archive, to: out)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["..\\..\\escaped.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent()
            .appendingPathComponent("escaped.txt").path))
    }

    func testArchiveStaysReadableForOlderSafeArchives() throws {
        // An archive written before the escape existed carries plain names and must still restore.
        let archive = root.appendingPathComponent("legacy.zip")
        try ZipWriter.write(entries: [
            ZipEntrySource(path: "saves/", isDirectory: true),
            ZipEntrySource(path: "saves/slot1.sav", data: Data("legacy".utf8)),
            ZipEntrySource(path: "saves/空 目录/角色.sav", data: Data("unicode".utf8)),
        ], to: archive)

        let out = root.appendingPathComponent("out")
        try ZipReader.extract(at: archive, to: out)

        XCTAssertEqual(TestSupport.contents(out, "saves/slot1.sav"), "legacy")
        XCTAssertEqual(TestSupport.contents(out, "saves/空 目录/角色.sav"), "unicode")
    }

    // MARK: - Old and new archives side by side

    /// The version marker, not the shape of a name, decides whether `%5C` means a backslash.
    func testArchiveVersionComesFromTheMarkerNotFromTheNames() throws {
        let legacy = root.appendingPathComponent("legacy.zip")
        try ZipWriter.write(entries: [ZipEntrySource(path: "%5Csavedata.bin", data: Data("legacy".utf8))],
                            to: legacy)
        let current = root.appendingPathComponent("current.zip")
        try ZipWriter.write(entries: [ZipEntrySource(path: "%5Csavedata.bin", data: Data("current".utf8))],
                            to: current, comment: ZipMarker.escapedPaths)

        XCTAssertNil(try ZipReader.comment(at: legacy))
        XCTAssertEqual(try ZipReader.comment(at: current), ZipMarker.escapedPaths)

        let legacyOut = root.appendingPathComponent("legacy-out")
        try ZipReader.extract(at: legacy, to: legacyOut)
        let currentOut = root.appendingPathComponent("current-out")
        try ZipReader.extract(at: current, to: currentOut)

        XCTAssertEqual(TestSupport.relativeFileList(legacyOut), ["%5Csavedata.bin"],
                       "a legacy name is a real name, not an escape")
        XCTAssertEqual(TestSupport.relativeFileList(currentOut), ["\\savedata.bin"],
                       "the same bytes in a marked archive decode to a backslash")
    }

    func testLegacyArchiveKeepsPercentSequencesInFileNames() throws {
        let contents = [
            "%5Csavedata.bin": "looks escaped",
            "%25literal.bin": "looks escaped too",
            "100% done.sav": "plain percent",
            "%5C dir/%25file.sav": "directory name as well",
        ]

        // The same folder built by hand is the reference for names, bytes and hash.
        let source = root.appendingPathComponent("legacy-source")
        try TestSupport.makeDirectory(source)
        for (path, text) in contents {
            try TestSupport.write(source, path, text, modified: stamp)
        }
        let expected = try SaveScanner().scan(directory: source, computeHash: true)

        let archive = root.appendingPathComponent("legacy.zip")
        let entries = contents
            .sorted { $0.key < $1.key }
            .map { ZipEntrySource(path: $0.key, data: Data($0.value.utf8), modificationDate: stamp) }
        try ZipWriter.write(entries: entries, to: archive)
        XCTAssertNil(try ZipReader.comment(at: archive))

        let out = root.appendingPathComponent("legacy-out")
        try ZipReader.extract(at: archive, to: out)

        XCTAssertEqual(TestSupport.relativeFileList(out), expected.files.map(\.relativePath).sorted())
        for (path, text) in contents {
            XCTAssertEqual(TestSupport.contents(out, path), text, "\(path) must keep its name and content")
        }
        XCTAssertEqual(try SaveScanner().scan(directory: out, computeHash: true).snapshot.contentHash,
                       expected.snapshot.contentHash,
                       "a legacy archive must reproduce the original folder hash")
    }

    func testNewArchiveRestoresPercentSequencesBackToTheOriginalNames() throws {
        let (scan, extracted) = try roundTrip([
            "%5Csavedata.bin": "is a literal percent escape in the name",
            "%25literal.bin": "also literal",
            "100% done.sav": "plain percent",
            "%5C dir/%25file.sav": "directory as well",
        ])
        try assertIdentical(scan, extracted)
        // Escaping is applied to the name, not interpreted: a file called `%5C…` stays `%5C…`.
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("%5Csavedata.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("%25literal.bin").path))
        XCTAssertEqual(TestSupport.contents(extracted, "100% done.sav"), "plain percent")
        XCTAssertEqual(TestSupport.contents(extracted, "%5C dir/%25file.sav"), "directory as well")
    }

    func testLegacyAndCurrentArchivesRestoreSideBySide() throws {
        // A device can hold one game archived by an older build and another by this one.
        let legacySource = root.appendingPathComponent("legacy-source")
        try TestSupport.makeDirectory(legacySource)
        try TestSupport.write(legacySource, "%5Cold.sav", "old build", modified: stamp)
        let legacyScan = try SaveScanner().scan(directory: legacySource, computeHash: true)
        let legacyArchive = root.appendingPathComponent("old-game.zip")
        let legacyEntries = try legacyScan.files.map {
            ZipEntrySource(path: $0.relativePath, data: try Data(contentsOf: $0.url), modificationDate: $0.modified)
        }
        try ZipWriter.write(entries: legacyEntries, to: legacyArchive)

        let (currentScan, currentOut) = try roundTrip(["\\new.sav": "new build"], gameId: "other-game")

        let legacyOut = root.appendingPathComponent("legacy-out")
        try ZipReader.extract(at: legacyArchive, to: legacyOut)

        XCTAssertEqual(TestSupport.relativeFileList(legacyOut), ["%5Cold.sav"])
        XCTAssertEqual(try SaveScanner().scan(directory: legacyOut, computeHash: true).snapshot.contentHash,
                       legacyScan.snapshot.contentHash)
        try assertIdentical(currentScan, currentOut)
    }
}
