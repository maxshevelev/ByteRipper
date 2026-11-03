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
        /// The code this revision published; nil from a client of an older
        /// server, and in a history written before revisions kept it.
        public var artifact: SHA256Digest?
        public var by: String?

        public init(reading: AnalysisReading, artifact: SHA256Digest? = nil, by: String? = nil) {
            self.reading = reading
            self.artifact = artifact
            self.by = by
        }
    }

    /// A publish's offer to the library registry: `ContentStore.putLibraryEntries`.
    public struct PutLibrary: Codable, Equatable, Sendable {
        public var module: SHA256Digest
        public var rev: Int?
        public var by: String?
        public var proposals: [LibraryProposal]
        /// Take every conflict, with `reason`; a client of the first form
        /// sends this and nothing else.
        public var take: Bool?
        public var reason: String?
        /// Take the entries named, each with its own reason — the second form,
        /// which a server that predates it ignores. Nil for a take of all.
        public var takeIDs: [String]?
        public var reasons: [String: String]?
        /// Answer what the offer would do and write nothing.
        public var dryRun: Bool?

        public init(module: SHA256Digest, rev: Int?, by: String?, proposals: [LibraryProposal],
                    take: Bool? = nil, reason: String? = nil,
                    takeIDs: [String]? = nil, reasons: [String: String]? = nil,
                    dryRun: Bool? = nil) {
            self.module = module
            self.rev = rev
            self.by = by
            self.proposals = proposals
            self.take = take
            self.reason = reason
            self.takeIDs = takeIDs
            self.reasons = reasons
            self.dryRun = dryRun
        }

        /// The decision this offer carries, as the store takes it.
        public var decision: LibraryTake {
            if let ids = takeIDs {
                var reasons = reasons ?? [:]
                for id in ids { reasons[id] = reasons[id] ?? "" }
                return .these(reasons)
            }
            return take == true ? .all(reason ?? "") : .none
        }

        private enum CodingKeys: String, CodingKey {
            case module, rev, by, proposals, take, reason, reasons
            case takeIDs = "take_ids"
            case dryRun = "dry_run"
        }
    }

    public struct SetRef: Codable, Equatable, Sendable {
        public var analyses: [AnalysisKey]

        public init(analyses: [AnalysisKey]) {
            self.analyses = analyses
        }
    }

    /// The objects asked of `POST objects/parts`. The answer is a run of
    /// frames, one per name in this order: the name in hex, its length as eight
    /// big-endian bytes, then that many bytes of gzip file; length 0 for an
    /// object the store does not have.
    public struct Parts: Codable, Equatable, Sendable {
        /// The most names one request may carry.
        public static let limit = 1024
        public var sha256: [SHA256Digest]

        public init(sha256: [SHA256Digest]) {
            self.sha256 = sha256
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
        /// The library registry changed: a mirror reads its index again. Nil
        /// from a server that predates the registry.
        public var library: Bool?

        public init(store: String, epoch: String, seq: Int, modules: [SHA256Digest], resync: Bool,
                    library: Bool? = nil) {
            self.store = store
            self.epoch = epoch
            self.seq = seq
            self.modules = modules
            self.resync = resync
            self.library = library
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public var error: String
        /// The rights a 403 is about, by name — `cas.write` — when the
        /// refusal names them (`Design/SERVER_HEADLESS_PLAN.md` decision 4).
        public var rights: [String]?
    }
}
