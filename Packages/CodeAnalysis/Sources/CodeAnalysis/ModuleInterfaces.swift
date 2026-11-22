import Foundation

/// What a module does with the PPIs and protocols of its phase, as its review
/// read it from the code: what it installs, what it looks up beyond its
/// dependency expression, and what it asks to be told about. Each list is nil
/// while the review has not gone through it, and an empty list is an answer:
/// the module does none of that. A review is not complete while any is nil
/// (`ReviewProgress`).
///
/// The dependency expression is not here: it is a section of the FFS file
/// beside the image, not a part of the image this record is keyed by — the
/// same image can sit in two files with two expressions — and the UEFI parser
/// reads it from the dump (`DependencyExpression`).
///
/// It travels in the review document (`interfaces`) and is copied into the
/// reading, so a list and the app's module popover show it without reading the
/// description, which may still discuss it in prose.
public struct ModuleInterfaces: Codable, Equatable, Hashable, Sendable {
    /// What the module installs: `InstallPpi`, `ReInstallPpi`, a list handed to
    /// the core at entry; `InstallProtocolInterface`,
    /// `InstallMultipleProtocolInterfaces`, `ReinstallProtocolInterface`.
    public var installs: [Interface]?
    /// What the module looks up outside its dependency expression:
    /// `LocatePpi`, `LocateProtocol`, `HandleProtocol` on a known GUID.
    public var locates: [Interface]?
    /// What the module asks to be told about: `NotifyPpi`,
    /// `RegisterProtocolNotify`, a notify event on a protocol.
    public var notifies: [Interface]?

    public init(installs: [Interface]? = nil, locates: [Interface]? = nil, notifies: [Interface]? = nil) {
        self.installs = installs
        self.locates = locates
        self.notifies = notifies
    }

    /// Whether the review has answered all three.
    public var isComplete: Bool { installs != nil && locates != nil && notifies != nil }

    /// The lists still unanswered, by their field names, in this order.
    public var unanswered: [String] {
        [("installs", installs), ("locates", locates), ("notifies", notifies)]
            .filter { $0.1 == nil }.map(\.0)
    }

    /// The record a review document carries, when it carries a readable one.
    public static func of(reviewDocument document: Data) -> ModuleInterfaces? {
        guard let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
              let record = object["interfaces"], !(record is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: record) else { return nil }
        return try? JSONDecoder().decode(ModuleInterfaces.self, from: data)
    }

    /// One PPI or protocol a module installs, locates or is notified of.
    public struct Interface: Codable, Equatable, Hashable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case ppi
            case `protocol`
        }

        /// How an install is made.
        public enum Method: String, Codable, CaseIterable, Sendable {
            /// `InstallPpi`, `InstallProtocolInterface`, `InstallMultiple…`.
            case install
            /// `ReInstallPpi`, `ReinstallProtocolInterface`: replaces one installed before.
            case reinstall
            /// A list handed over without a service call: SecCore's list to
            /// PeiCore, PeiCore's own at its start.
            case handoff
        }

        /// The GUID in its canonical form, upper case:
        /// `0AE8CE5D-E448-4437-A8D7-EBF5F194F731`.
        public var guid: String
        /// Its name as the code and the GUID table know it:
        /// `EFI_PEI_MEMORY_DISCOVERED_PPI`.
        public var name: String
        public var kind: Kind
        /// Where the module supplies the GUID or its descriptor: the call — to
        /// the service or to a wrapper the module calls — or the descriptor or
        /// list itself where no call of the module's holds it. Several entries
        /// may share it: one call installs a descriptor list.
        public var address: String
        /// When it happens: `always`, or the condition in the review's words
        /// ("only on S3 resume", "only in recovery").
        public var condition: String
        /// Why the module needs it and what it gives, in a sentence or two:
        /// what the interface is used for here, and anything particular about
        /// its use. Required: an entry without it is refused.
        public var purpose: String
        /// For an install; nil reads as `install`.
        public var method: Method?
        /// For a lookup: whether the module stops or fails without it.
        public var required: Bool?
        /// For a notification: the entry of the function called.
        public var callback: String?

        public init(guid: String, name: String, kind: Kind, address: String, condition: String,
                    purpose: String, method: Method? = nil, required: Bool? = nil, callback: String? = nil) {
            self.guid = guid
            self.name = name
            self.kind = kind
            self.address = address
            self.condition = condition
            self.purpose = purpose
            self.method = method
            self.required = required
            self.callback = callback
        }
    }
}
