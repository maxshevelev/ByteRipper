import CryptoKit
import Foundation

/// The version of the on-disk manifest and bundle shapes. A reader refuses a
/// number it does not know rather than guessing at a newer file.
public enum CodeAnalysisSchema {
    public static let current = 1
}

/// A SHA-256 as sixty-four lower-case hex digits.
///
/// A type rather than a string because a digest is a key, not a note: the
/// store's paths, the manifests and the bundles all have to agree on its
/// spelling, and a wrong one has to be refused at the boundary rather than
/// become a directory name.
public struct SHA256Digest: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let hex: String

    public init?(hex: String) {
        let lowered = hex.lowercased()
        guard lowered.count == 64,
              lowered.allSatisfy({ $0.isHexDigit })
        else { return nil }
        self.hex = lowered
    }

    public init(data: Data) {
        self.hex = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public var description: String { hex }

    public static func < (lhs: SHA256Digest, rhs: SHA256Digest) -> Bool {
        lhs.hex < rhs.hex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let digest = SHA256Digest(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(text) is not a SHA-256")
        }
        self = digest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The manifest's address: a module's bytes and the recipe that analyzed them.
///
/// The same module with another exporter or another Ghidra is a different key,
/// which is why an analysis is never silently overwritten by a newer tool.
public struct AnalysisKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let module: SHA256Digest
    public let recipe: String

    public init?(module: SHA256Digest, recipe: String) {
        guard SafeName.isSafe(recipe) else { return nil }
        self.module = module
        self.recipe = recipe
    }

    /// `"<module-sha>/<recipe>"`, the form a reference and a bundle list.
    public init?(_ text: String) {
        guard let slash = text.firstIndex(of: "/") else { return nil }
        let moduleText = String(text[..<slash])
        let recipe = String(text[text.index(after: slash)...])
        guard let module = SHA256Digest(hex: moduleText) else { return nil }
        self.init(module: module, recipe: recipe)
    }

    public var description: String { "\(module.hex)/\(recipe)" }

    public static func < (lhs: AnalysisKey, rhs: AnalysisKey) -> Bool {
        lhs.description < rhs.description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let key = AnalysisKey(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(text) is not <module-sha>/<recipe>")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The module bytes an analysis belongs to. The hash names the bytes; the rest
/// is what the panel shows beside them.
public struct ModuleIdentity: Codable, Equatable, Sendable {
    public var sha256: SHA256Digest
    public var size: Int
    public var name: String
    public var kind: String?
    public var language: String?
    public var imageBase: String?

    public init(sha256: SHA256Digest, size: Int, name: String,
                kind: String? = nil, language: String? = nil, imageBase: String? = nil) {
        self.sha256 = sha256
        self.size = size
        self.name = name
        self.kind = kind
        self.language = language
        self.imageBase = imageBase
    }

    private enum CodingKeys: String, CodingKey {
        case sha256, size, name, kind, language
        case imageBase = "image_base"
    }
}

/// What produced an analysis: the exporter's version and the Ghidra that ran.
public struct AnalysisRecipe: Codable, Equatable, Sendable {
    public var id: String
    public var exporter: Int
    public var ghidra: String?
    public var script: String

    public init(id: String, exporter: Int, ghidra: String?, script: String) {
        self.id = id
        self.exporter = exporter
        self.ghidra = ghidra
        self.script = script
    }

    /// The recipe as a path-safe name, e.g. `code-v2-ghidra-12.1.2`.
    public static func identifier(exporter: Int, ghidra: String?) -> String {
        let raw = ghidra ?? "unknown"
        let cleaned = raw
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "code-v\(exporter)-ghidra-\(cleaned.isEmpty ? "unknown" : cleaned)"
    }
}

/// The object a manifest names.
public struct AnalysisArtifact: Codable, Equatable, Sendable {
    public var sha256: SHA256Digest
    public var size: Int
    public var mediaType: String

    public init(sha256: SHA256Digest, size: Int, mediaType: String) {
        self.sha256 = sha256
        self.size = size
        self.mediaType = mediaType
    }

    private enum CodingKeys: String, CodingKey {
        case sha256, size
        case mediaType = "media_type"
    }
}

/// Where the module came from, when the caller knows.
public struct SourceIdentity: Codable, Equatable, Sendable {
    public var path: String?
    public var document: String?
    public var node: String?

    public init(path: String? = nil, document: String? = nil, node: String? = nil) {
        self.path = path
        self.document = document
        self.node = node
    }
}

/// What the artifact holds, counted without parsing its contents here.
public struct AnalysisStats: Codable, Equatable, Sendable {
    public var functions: Int
    public var instructions: Int
    public var strings: Int
    public var postCodeWrites: Int
    public var statusCodeCandidates: Int

    public init(functions: Int = 0, instructions: Int = 0, strings: Int = 0,
                postCodeWrites: Int = 0, statusCodeCandidates: Int = 0) {
        self.functions = functions
        self.instructions = instructions
        self.strings = strings
        self.postCodeWrites = postCodeWrites
        self.statusCodeCandidates = statusCodeCandidates
    }

    private enum CodingKeys: String, CodingKey {
        case functions, instructions, strings
        case postCodeWrites = "post_code_writes"
        case statusCodeCandidates = "status_code_candidates"
    }
}

/// One analysis: which module, which recipe, which object, and what it holds.
public struct AnalysisManifest: Codable, Equatable, Sendable {
    public var schema: Int
    public var module: ModuleIdentity
    public var recipe: AnalysisRecipe
    public var artifact: AnalysisArtifact
    public var source: SourceIdentity
    public var analyzedAt: String
    public var stats: AnalysisStats

    public init(schema: Int = CodeAnalysisSchema.current, module: ModuleIdentity,
                recipe: AnalysisRecipe, artifact: AnalysisArtifact,
                source: SourceIdentity = SourceIdentity(),
                analyzedAt: String, stats: AnalysisStats) {
        self.schema = schema
        self.module = module
        self.recipe = recipe
        self.artifact = artifact
        self.source = source
        self.analyzedAt = analyzedAt
        self.stats = stats
    }

    public var key: AnalysisKey? { AnalysisKey(module: module.sha256, recipe: recipe.id) }

    private enum CodingKeys: String, CodingKey {
        case schema, module, recipe, artifact, source, stats
        case analyzedAt = "analyzed_at"
    }
}

/// A named set of analyses a project or a person keeps. Garbage collection
/// removes what no reference reaches.
public struct AnalysisRef: Codable, Equatable, Sendable {
    public var name: String
    public var analyses: [AnalysisKey]
    public var updatedAt: String

    public init(name: String, analyses: [AnalysisKey], updatedAt: String) {
        self.name = name
        self.analyses = analyses
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, analyses
        case updatedAt = "updated_at"
    }
}

/// What a collection pass did, or would do.
public struct GarbageReport: Codable, Equatable, Sendable {
    public var objects: Int
    public var analyses: Int
    public var keptAnalyses: Int
    public var keptObjects: Int
    public var dryRun: Bool

    public init(objects: Int, analyses: Int, keptAnalyses: Int,
                keptObjects: Int, dryRun: Bool) {
        self.objects = objects
        self.analyses = analyses
        self.keptAnalyses = keptAnalyses
        self.keptObjects = keptObjects
        self.dryRun = dryRun
    }

    private enum CodingKeys: String, CodingKey {
        case objects, analyses
        case keptAnalyses = "kept_analyses"
        case keptObjects = "kept_objects"
        case dryRun = "dry_run"
    }
}

/// The list a bundle carries: what it holds, and when it was written.
public struct BundleInfo: Codable, Equatable, Sendable {
    public var schema: Int
    public var createdAt: String
    public var analyses: [AnalysisKey]

    public init(schema: Int = CodeAnalysisSchema.current, createdAt: String,
                analyses: [AnalysisKey]) {
        self.schema = schema
        self.createdAt = createdAt
        self.analyses = analyses
    }

    private enum CodingKeys: String, CodingKey {
        case schema, analyses
        case createdAt = "created_at"
    }
}

/// A file or directory name the store may use: ASCII letters, digits, dot,
/// underscore and hyphen; not empty, and not a path traversal.
enum SafeName {
    static func isSafe(_ text: String) -> Bool {
        guard !text.isEmpty, text != ".", text != ".." else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x2E, 0x5F, 0x2D:
                return true
            default:
                return false
            }
        }
    }
}

/// The ISO-8601 time the Python store writes: seconds, and `+00:00` for UTC,
/// so a manifest written by either side sorts with the other. The offset is
/// written out rather than left to `XXX`: on this platform that reads back `Z`,
/// and the Python side writes `+00:00`.
enum Timestamps {
    static func now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+00:00'"
        return formatter.string(from: Date())
    }
}
