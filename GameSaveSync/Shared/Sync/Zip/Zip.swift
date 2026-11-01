import Foundation
import Compression

public enum CRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        return table
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

/// Raw DEFLATE helpers built on Apple's Compression framework.
///
/// `COMPRESSION_ZLIB` produces a bare DEFLATE stream (no zlib header), which is exactly what
/// ZIP method 8 expects.
public enum Deflate {
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return process(data, operation: COMPRESSION_STREAM_ENCODE)
    }

    public static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        guard !data.isEmpty else { return nil }
        return process(data, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func process(_ input: Data, operation: compression_stream_operation) -> Data? {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        var failure = false
        var finished = false

        input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                finished = true
                return
            }
            stream.src_ptr = base
            stream.src_size = raw.count

            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == COMPRESSION_STATUS_END {
                    finished = true
                    return
                }
                if status == COMPRESSION_STATUS_ERROR {
                    failure = true
                    return
                }
                if produced == 0 && stream.src_size == 0 {
                    // No more input and no output: the stream is finished without an explicit END.
                    finished = true
                    return
                }
                if output.count > 8 << 30 {
                    failure = true
                    return
                }
            }
        }

        guard finished, !failure else { return nil }
        return output
    }
}

/// Converts between `Date` and MS-DOS date/time pairs.
///
/// DOS timestamps only have 2-second resolution and no time zone, so they are informational
/// only. GameSaveSync stores exact timestamps inside the archive metadata file.
enum DOSDate {
    static func encode(_ date: Date, calendar: Calendar = .current) -> (time: UInt16, date: UInt16) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)
        let dosTime = UInt16(hour << 11 | minute << 5 | (second / 2))
        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        return (dosTime, dosDate)
    }

    static func decode(time: UInt16, date: UInt16, calendar: Calendar = .current) -> Date {
        let year = Int((date >> 9) & 0x7F) + 1980
        let month = Int((date >> 5) & 0x0F)
        let day = Int(date & 0x1F)
        let hour = Int((time >> 11) & 0x1F)
        let minute = Int((time >> 5) & 0x3F)
        let second = Int(time & 0x1F) * 2
        var components = DateComponents()
        components.year = year
        components.month = max(month, 1)
        components.day = max(day, 1)
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}

public enum ZipError: Error, Equatable {
    case writeFailed(String)
    case readFailed(String)
    case unsupportedZip64(String)
    case unsafePath(String)
    case checksumMismatch(String)
    case tooLarge(String)
}

public struct ZipEntrySource: Sendable {
    public var path: String
    public var data: Data
    public var modificationDate: Date
    public var isDirectory: Bool

    public init(path: String, data: Data = Data(), modificationDate: Date = Date(), isDirectory: Bool = false) {
        self.path = path
        self.data = data
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
    }
}

/// Declares how an archive stored its entry names, so a reader never has to guess from the names.
///
/// The marker is the archive comment in the end-of-central-directory record. Archives written
/// before escaping existed have no comment at all, which is what identifies them as version 1;
/// a plain name such as `%5Cdata.bin` in such an archive is a real file name and must not be
/// decoded.
public enum ZipMarker {
    /// Entry names were escaped with ``ArchivePath``: `\` → `%5C`, `%` → `%25`.
    public static let escapedPaths = "GameSaveSync path encoding 2"
}

public enum ZipWriter {
    private static let localSignature: UInt32 = 0x04034b50
    private static let centralSignature: UInt32 = 0x02014b50
    private static let endSignature: UInt32 = 0x06054b50

    /// `comment` is stored in the end-of-central-directory record. It is how an archive declares
    /// which naming scheme its entry names use; see ``ZipMarker``.
    public static func write(entries: [ZipEntrySource], to url: URL, comment: String? = nil) throws {
        guard entries.count <= 65535 else {
            throw ZipError.unsupportedZip64("more than 65535 entries")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ZipError.writeFailed("cannot open \(url.lastPathComponent) for writing")
        }
        defer { try? handle.close() }

        var offset: UInt32 = 0
        var central = Data()

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            guard nameData.count <= 65535 else {
                throw ZipError.writeFailed("path too long: \(entry.path)")
            }
            let crc = CRC32.checksum(entry.data)
            let uncompressed = entry.data.count
            var method: UInt16 = 0
            var payload = entry.data

            if !entry.data.isEmpty, let compressed = Deflate.compress(entry.data), compressed.count < entry.data.count {
                method = 8
                payload = compressed
            }

            guard payload.count <= Int(UInt32.max), uncompressed <= Int(UInt32.max) else {
                throw ZipError.tooLarge("entry too large: \(entry.path)")
            }
            guard offset <= UInt32.max else {
                throw ZipError.tooLarge("archive larger than 4 GB")
            }

            let stamp = DOSDate.encode(entry.modificationDate)
            let flags: UInt16 = 0x0800 // UTF-8 names
            var header = Data()
            header.appendLE(localSignature)
            header.appendLE(UInt16(20))
            header.appendLE(flags)
            header.appendLE(method)
            header.appendLE(stamp.time)
            header.appendLE(stamp.date)
            header.appendLE(crc)
            header.appendLE(UInt32(payload.count))
            header.appendLE(UInt32(uncompressed))
            header.appendLE(UInt16(nameData.count))
            header.appendLE(UInt16(0))
            header.append(nameData)

            try handle.write(contentsOf: header)
            if !payload.isEmpty {
                try handle.write(contentsOf: payload)
            }

            let mode: UInt32 = entry.isDirectory ? 0o040755 : 0o100644
            central.appendLE(centralSignature)
            central.appendLE(UInt16((3 << 8) | 45)) // made by: unix, spec 4.5
            central.appendLE(UInt16(20))
            central.appendLE(flags)
            central.appendLE(method)
            central.appendLE(stamp.time)
            central.appendLE(stamp.date)
            central.appendLE(crc)
            central.appendLE(UInt32(payload.count))
            central.appendLE(UInt32(uncompressed))
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(mode << 16)
            central.appendLE(offset)
            central.append(nameData)

            offset += UInt32(header.count) + UInt32(payload.count)
        }

        guard offset <= UInt32.max, central.count <= UInt32.max else {
            throw ZipError.tooLarge("archive larger than 4 GB")
        }
        let centralOffset = offset
        try handle.write(contentsOf: central)

        let commentData = Data((comment ?? "").utf8)
        guard commentData.count <= 65535 else {
            throw ZipError.writeFailed("archive comment too long")
        }

        var end = Data()
        end.appendLE(endSignature)
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt32(central.count))
        end.appendLE(centralOffset)
        end.appendLE(UInt16(commentData.count))
        end.append(commentData)
        try handle.write(contentsOf: end)
    }
}

public struct ZipEntryInfo: Sendable {
    public let path: String
    public let isDirectory: Bool
    public let method: UInt16
    public let crc: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let localHeaderOffset: Int
    public let modificationDate: Date
    public let unixPermissions: UInt16

    public var isSymlink: Bool { (unixPermissions & 0xF000) == 0xA000 }
}

public enum ZipReader {
    private static let localSignature: UInt32 = 0x04034b50
    private static let centralSignature: UInt32 = 0x02014b50
    private static let endSignature: UInt32 = 0x06054b50

    public static func entries(at url: URL) throws -> [ZipEntryInfo] {
        try parseDirectory(try mapped(url)).entries
    }

    /// Archive comment, used as the format marker (see ``ZipMarker``). `nil` for archives that do
    /// not carry one, which is every archive written before the marker existed.
    public static func comment(at url: URL) throws -> String? {
        try parseDirectory(try mapped(url)).comment
    }

    private struct Directory {
        let entries: [ZipEntryInfo]
        let comment: String?
    }

    private static func mapped(_ url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ZipError.readFailed("cannot read \(url.lastPathComponent)")
        }
        return data
    }

    private static func parseDirectory(_ data: Data) throws -> Directory {
        guard data.count >= 22 else {
            throw ZipError.readFailed("archive is too small")
        }
        let searchLimit = max(0, data.count - 65_557)
        var eocd: Int?
        var index = data.count - 22
        while index >= searchLimit {
            if data.readUInt32(at: index) == endSignature,
               index + 22 + Int(data.readUInt16(at: index + 20)) <= data.count {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else {
            throw ZipError.readFailed("end of central directory not found")
        }

        let entryCount = Int(data.readUInt16(at: eocd + 10))
        let centralSize = Int(data.readUInt32(at: eocd + 12))
        let centralOffset = Int(data.readUInt32(at: eocd + 16))
        let archiveCommentLength = Int(data.readUInt16(at: eocd + 20))
        let comment: String?
        if archiveCommentLength > 0, eocd + 22 + archiveCommentLength <= data.count {
            comment = String(data: data.subdata(in: (eocd + 22)..<(eocd + 22 + archiveCommentLength)),
                             encoding: .utf8)
        } else {
            comment = nil
        }

        if entryCount == 0xFFFF || centralOffset == 0xFFFF_FFFF || centralSize == 0xFFFF_FFFF {
            throw ZipError.unsupportedZip64("ZIP64 archives are not supported")
        }
        guard centralOffset >= 0, centralSize >= 0, centralOffset + centralSize <= data.count else {
            throw ZipError.readFailed("central directory out of bounds")
        }

        var entries: [ZipEntryInfo] = []
        entries.reserveCapacity(entryCount)
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, data.readUInt32(at: cursor) == centralSignature else {
                throw ZipError.readFailed("bad central directory entry")
            }
            let madeBy = data.readUInt16(at: cursor + 4)
            let method = data.readUInt16(at: cursor + 10)
            let dosTime = data.readUInt16(at: cursor + 12)
            let dosDate = data.readUInt16(at: cursor + 14)
            let crc = data.readUInt32(at: cursor + 16)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let externalAttributes = data.readUInt32(at: cursor + 38)
            let localOffset = Int(data.readUInt32(at: cursor + 42))

            guard cursor + 46 + nameLength <= data.count else {
                throw ZipError.readFailed("truncated central directory entry")
            }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let rawName = String(data: nameData, encoding: .utf8) else {
                throw ZipError.readFailed("entry name is not valid UTF-8")
            }
            let isDirectory = rawName.hasSuffix("/")
            let permissions: UInt16 = madeBy >> 8 == 3 ? UInt16((externalAttributes >> 16) & 0xFFFF) : 0

            entries.append(ZipEntryInfo(path: rawName,
                                        isDirectory: isDirectory,
                                        method: method,
                                        crc: crc,
                                        compressedSize: compressedSize,
                                        uncompressedSize: uncompressedSize,
                                        localHeaderOffset: localOffset,
                                        modificationDate: DOSDate.decode(time: dosTime, date: dosDate),
                                        unixPermissions: permissions))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return Directory(entries: entries, comment: comment)
    }

    /// Extracts an archive into `destination`. Every entry name is validated, CRCs are checked,
    /// and nothing outside `destination` can ever be written.
    ///
    /// Names are un-escaped with ``ArchivePath`` only when the archive carries the
    /// ``ZipMarker/escapedPaths`` marker. Archives written before that marker existed store raw
    /// names, so a file that really is called `%5Cdata.bin` keeps its name.
    @discardableResult
    public static func extract(at url: URL, to destination: URL, maxTotalBytes: Int64 = 8 << 30) throws -> [String] {
        let data = try mapped(url)
        let directory = try parseDirectory(data)
        let entries = directory.entries
        let escapesPaths = directory.comment == ZipMarker.escapedPaths
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let rootPath = FileSystem.canonicalPath(for: destination)

        var written: [String] = []
        var totalBytes: Int64 = 0

        for entry in entries {
            let validated = try SafePath.relativePath(fromArchiveEntry: entry.path, isDirectory: entry.isDirectory)
            if validated.isEmpty { continue }
            if entry.isSymlink {
                throw ZipError.unsafePath("symbolic link entry: \(entry.path)")
            }
            // A marker-bearing archive escapes its names (see `ArchivePath`), so validation runs on
            // a name that can only use `/` as a separator and the decoded name is what the save
            // folder really holds. A legacy archive stores names verbatim and is left alone.
            let relative = escapesPaths ? ArchivePath.decode(validated) : validated
            let target = destination.appendingPathComponent(relative)
            let standardized = FileSystem.canonicalPath(for: target)
            guard standardized == rootPath || standardized.hasPrefix(rootPath + "/") else {
                throw ZipError.unsafePath(entry.path)
            }

            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            totalBytes += Int64(entry.uncompressedSize)
            guard totalBytes <= maxTotalBytes else {
                throw ZipError.tooLarge("archive expands to more than \(maxTotalBytes) bytes")
            }

            guard entry.localHeaderOffset + 30 <= data.count,
                  data.readUInt32(at: entry.localHeaderOffset) == localSignature else {
                throw ZipError.readFailed("bad local header for \(entry.path)")
            }
            let nameLength = Int(data.readUInt16(at: entry.localHeaderOffset + 26))
            let extraLength = Int(data.readUInt16(at: entry.localHeaderOffset + 28))
            let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
            guard dataStart + entry.compressedSize <= data.count else {
                throw ZipError.readFailed("truncated data for \(entry.path)")
            }
            let payload = data.subdata(in: dataStart..<(dataStart + entry.compressedSize))

            let contents: Data
            switch entry.method {
            case 0:
                contents = payload
            case 8:
                guard let inflated = Deflate.decompress(payload, expectedSize: entry.uncompressedSize) else {
                    throw ZipError.readFailed("cannot inflate \(entry.path)")
                }
                contents = inflated
            default:
                throw ZipError.readFailed("unsupported compression method \(entry.method)")
            }

            guard contents.count == entry.uncompressedSize else {
                throw ZipError.checksumMismatch("size mismatch for \(entry.path)")
            }
            guard CRC32.checksum(contents) == entry.crc else {
                throw ZipError.checksumMismatch("CRC mismatch for \(entry.path)")
            }

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, options: .atomic)
            try? fm.setAttributes([.modificationDate: entry.modificationDate], ofItemAtPath: target.path)
            written.append(relative)
        }

        return written
    }
}

public enum SafePath {
    /// Turns an archive entry name into a relative path that cannot escape its destination.
    ///
    /// Entry names are never allowed to carry a raw backslash: on Windows it is a separator and
    /// `..\..\x` is a traversal. Save folders can legitimately contain a file called
    /// `\savedata0.bin`, so such names are escaped by `ArchivePath` before they are stored and
    /// decoded again after this check has passed.
    public static func relativePath(fromArchiveEntry raw: String, isDirectory: Bool) throws -> String {
        guard !raw.isEmpty, !raw.contains("\0") else {
            throw ZipError.unsafePath(raw)
        }
        var name = raw
        if name.hasSuffix("/") { name.removeLast() }
        guard !name.isEmpty else { return "" }

        guard !name.hasPrefix("/"), !name.hasPrefix("\\") else {
            throw ZipError.unsafePath(raw)
        }
        if name.contains("\\") { throw ZipError.unsafePath(raw) }
        if name.count >= 2 {
            let scalars = Array(name.unicodeScalars.prefix(2))
            if scalars[0].properties.isASCIIHexDigit, scalars[1] == ":" {
                throw ZipError.unsafePath(raw)
            }
        }

        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        var cleaned: [String] = []
        for component in components {
            let part = String(component)
            if part.isEmpty || part == "." { continue }
            if part == ".." { throw ZipError.unsafePath(raw) }
            if part.contains(":") { throw ZipError.unsafePath(raw) }
            cleaned.append(part)
        }
        guard !cleaned.isEmpty else { throw ZipError.unsafePath(raw) }
        _ = isDirectory
        return cleaned.joined(separator: "/")
    }
}

/// Maps a save folder path to a ZIP entry name and back.
///
/// A backslash is a perfectly legal character in an APFS file name, and games that were written
/// for Windows really do create files such as `\savedata0.bin`. Storing that name verbatim would
/// make the archive ambiguous — some extractors read `\` as a directory separator — and would be
/// rejected by ``SafePath``, which treats any raw backslash in an entry name as hostile.
///
/// So both characters that could be misread are percent-escaped per path component:
///
/// | character | stored as |
/// | --- | --- |
/// | `\` | `%5C` |
/// | `%` | `%25` |
///
/// The mapping is reversible: every `%` is escaped, so a name that already contains `%5C` survives
/// a round trip unchanged. Components without either character are stored verbatim, which keeps
/// ordinary archives byte-identical to what earlier versions produced. Decoding only recognises
/// the two escapes above, so a plain name such as `100%done.sav` is left alone.
public enum ArchivePath {
    public static func encode(_ relativePath: String) -> String {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(encodeComponent)
            .joined(separator: "/")
    }

    public static func decode(_ entryName: String) -> String {
        guard entryName.contains("%") else { return entryName }
        return entryName
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(decodeComponent)
            .joined(separator: "/")
    }

    private static func encodeComponent(_ component: Substring) -> String {
        guard component.contains("\\") || component.contains("%") else { return String(component) }
        var encoded = ""
        encoded.reserveCapacity(component.count)
        for character in component {
            switch character {
            case "\\": encoded += "%5C"
            case "%": encoded += "%25"
            default: encoded.append(character)
            }
        }
        return encoded
    }

    private static func decodeComponent(_ component: Substring) -> String {
        guard component.contains("%") else { return String(component) }
        var decoded = ""
        var rest = component[...]
        while let percent = rest.firstIndex(of: "%") {
            decoded.append(contentsOf: rest[rest.startIndex..<percent])
            let escape = rest[percent...]
            if escape.hasPrefix("%25") {
                decoded.append("%")
                rest = escape.dropFirst(3)
            } else if escape.hasPrefix("%5C") {
                decoded.append("\\")
                rest = escape.dropFirst(3)
            } else {
                // Not an escape this codec writes: keep the character as part of the file name.
                decoded.append("%")
                rest = escape.dropFirst()
            }
        }
        decoded.append(contentsOf: rest)
        return decoded
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
