import Foundation

public enum Coders {
    /// ISO-8601 with fractional seconds so that save timestamps keep sub-second precision.
    public static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = iso8601.date(from: text) ?? iso8601NoFraction.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(text)")
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
        try makeEncoder(pretty: pretty).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }
}

public enum DateText {
    public static func stamp(_ date: Date?, language: ResolvedLanguage) -> String {
        guard let date else { return language == .chinese ? "从未" : "Never" }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public static func dayTime(_ date: Date, language: ResolvedLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

public enum ByteText {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: max(bytes, 0))
    }
}

public enum Slugger {
    /// Builds a stable game id: lowercase ASCII, words joined with dashes.
    public static func slug(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        var scalars: [Character] = []
        for character in folded.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                scalars.append(character)
            } else if !scalars.isEmpty, scalars.last != "-" {
                scalars.append("-")
            }
        }
        while scalars.last == "-" { scalars.removeLast() }
        let slug = String(scalars)
        return slug.isEmpty ? "game" : String(slug.prefix(48))
    }

    /// Game ids are used as directory names, so restrict them to a safe subset.
    public static func sanitizeGameId(_ raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                result.append(character)
            } else if character == " " {
                result.append("-")
            }
        }
        while result.hasPrefix(".") { result.removeFirst() }
        while result.hasSuffix(".") { result.removeLast() }
        return String(result.prefix(64))
    }

    public static func isValidGameId(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 64 else { return false }
        guard raw.first != ".", raw.last != "." else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        return raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
