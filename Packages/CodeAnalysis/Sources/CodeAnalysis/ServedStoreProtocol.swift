import Foundation

/// The bodies a served store (`CASService`, under `/cas/v1`) and its client
/// (`RemoteStore`) exchange. Both sides decode the same types, so the protocol
/// is written once (`Design/SERVER_PLAN.md` §4).
public enum ServedStoreProtocol {
    /// Raised when an answer changes shape, never for an addition.
    public static let version = 1
    public static let prefix = "/cas/v1"

    public struct Hello: Codable, Equatable, Sendable {
        public var protocolVersion: Int
        /// The served store's `identity()`.
        public var store: String
        /// Minted when the server starts: a sequence number means something
        /// only within one epoch.
        public var epoch: String
        public var seq: Int

        public init(protocolVersion: Int = ServedStoreProtocol.version, store: String,
                    epoch: String, seq: Int) {
            self.protocolVersion = protocolVersion
            self.store = store
            self.epoch = epoch
            self.seq = seq
        }

        private enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case store, epoch, seq
        }
    }

    public struct Modules: Codable, Equatable, Sendable {
        public var modules: [ServedModule]

        public init(modules: [ServedModule]) {
            self.modules = modules
        }
    }

    public struct PutAnalysis: Codable, Equatable, Sendable {
        public var module: ModuleIdentity
        public var recipe: AnalysisRecipe
        /// An object put before this call.
        public var artifact: SHA256Digest
        public var source: SourceIdentity?
        public var reading: AnalysisReading?
        public var replace: Bool?
        public var discardReading: Bool?

        public init(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: SHA256Digest,
                    source: SourceIdentity? = nil, reading: AnalysisReading? = nil,
                    replace: Bool? = nil, discardReading: Bool? = nil) {
            self.module = module
            self.recipe = recipe
            self.artifact = artifact
            self.source = source
            self.reading = reading
            self.replace = replace
            self.discardReading = discardReading
        }

        private enum CodingKeys: String, CodingKey {
            case module, recipe, artifact, source, reading, replace
            case discardReading = "discard_reading"
        }
    }

    public struct RecordRevision: Codable, Equatable, Sendable {
        public var reading: AnalysisReading
        public var by: String?

        public init(reading: AnalysisReading, by: String? = nil) {
            self.reading = reading
            self.by = by
        }
    }

    public struct SetRef: Codable, Equatable, Sendable {
        public var analyses: [AnalysisKey]

        public init(analyses: [AnalysisKey]) {
            self.analyses = analyses
        }
    }

    public struct Export: Codable, Equatable, Sendable {
        public var keys: [AnalysisKey]

        public init(keys: [AnalysisKey]) {
            self.keys = keys
        }
    }

    public struct Problems: Codable, Equatable, Sendable {
        public var problems: [String]

        public init(problems: [String]) {
            self.problems = problems
        }
    }

    /// What changed since a sequence number. `resync` says the client cannot
    /// tell from the list — another epoch, or further back than the server
    /// remembers — and must read every module again.
    public struct Changes: Codable, Equatable, Sendable {
        public var store: String
        public var epoch: String
        public var seq: Int
        public var modules: [SHA256Digest]
        public var resync: Bool

        public init(store: String, epoch: String, seq: Int, modules: [SHA256Digest], resync: Bool) {
            self.store = store
            self.epoch = epoch
            self.seq = seq
            self.modules = modules
            self.resync = resync
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public var error: String
        /// The right a 403 is about, by its name — `cas.write` — when the
        /// refusal names one (`Design/SERVER_HEADLESS_PLAN.md` decision 4).
        public var right: String?
    }
}
