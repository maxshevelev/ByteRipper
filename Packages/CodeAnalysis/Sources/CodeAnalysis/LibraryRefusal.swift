import Foundation

/// A library function lives in the registry, never in a module
/// (`Design/LIBRARY_REGISTRY_PLAN.md`). A publish takes the review's candidates to
/// the registry, or is refused: this says which, and why.
public enum LibraryRefusal {
    public struct Row: Equatable, Sendable {
        public var address: String?
        public var name: String
        public var why: String
        /// The registry entry this row would replace, when that is why it is
        /// refused: what a proposal of the replacement names.
        public var entry: String?

        public init(address: String?, name: String, why: String, entry: String? = nil) {
            self.address = address
            self.name = name
            self.why = why
            self.entry = entry
        }

        var said: String {
            "\(name)\(address.map { " at \($0)" } ?? ""): \(why)"
        }
    }

    /// Why nothing moved; nil when the registry takes every function.
    public static func refusal(_ rows: [Row]) -> String? {
        guard !rows.isEmpty else { return nil }
        return "the registry does not take these: " + rows.map(\.said).joined(separator: "; ")
            + ". Nothing was stored."
    }

    /// What a reviewer does about a GUID global that did not pass.
    static func guidHint(_ global: LibraryGlobal) -> String {
        guard let guid = global.guid else { return "" }
        if let held = global.registryName {
            return ": the GUID registry names \(guid) \(held), name the global so"
        }
        return ": the GUID registry does not hold \(guid), add it with `ghidra_guid_add`, then name the global as the registry does"
    }

    /// The functions a registry answer does not take.
    public static func rows(of result: LibraryWriteResult) -> [Row] {
        var rows: [Row] = (result.notLibrary ?? []).map { row in
            let why: String
            switch row.why {
            case "data":
                why = "the registry refused it, it reads data no citation covers: "
                    + (row.data ?? []).map { offset in
                        guard let global = row.globals?.first(where: { $0.offset == offset }) else {
                            return "a datum at +\(offset)"
                        }
                        return global.said + Self.guidHint(global)
                    }.joined(separator: ", ")
                    + " (a global a review named and typed with a shared type is no obstacle, nor a GUID "
                    + "under the GUID registry's name for its value, nor a string in an `amd` or `intel` body, "
                    + "whose bytes enter the entry; an `edk2` body's string needs its line cited with `ghidra_library_cite`)"
            case "callee":
                why = "the registry refused it, it calls what the registry does not hold: "
                    + (row.callees ?? []).joined(separator: ", ")
            case "dependency":
                why = "the registry refused it, it calls a library its own does not depend on: "
                    + (row.callees ?? []).joined(separator: ", ")
            case "global":
                why = "the registry refused it, " + (row.reason ?? "its global is not of the type the entry reads")
            case "library":
                why = "the registry refused it, it declares no such library"
            case "taken_out":
                // The reason was written about the review the entry held,
                // and an address in it is that module's, not this one's.
                let of = row.reasonOf.map {
                    " (written of module \($0.module.hex), function at \($0.address); its addresses are that module's)"
                } ?? ""
                why = "taken out of the registry" + (row.reason.map { ": \($0)\(of)" } ?? "")
            default:
                why = "the registry refused it: \(row.why)"
            }
            return Row(address: row.address, name: row.name, why: why)
        }
        rows += (result.nameConflicts ?? []).map {
            Row(address: $0.address, name: $0.name, why: LibraryBody.isShort(key: $0.body)
                ? "entry \($0.heldBy) holds that name: if this is that function, bind it with `ghidra_library_apply`"
                : "entry \($0.heldBy) holds that name for another body")
        }
        rows += result.conflicts.map { conflict -> Row in
            let changed = (conflict.changed ?? []).filter { !["body", "constants", "function"].contains($0) }
            let what = changed.isEmpty ? "what it says" : changed.joined(separator: ", ")
            let printed = conflict.names.map { " (\($0.joined(separator: ", ")))" } ?? ""
            return Row(address: nil, name: conflict.proposedName,
                       why: "this review replaces \(what) of entry \(conflict.id), version \(conflict.version), "
                           + "written by module \(conflict.heldBy.module.hex) at \(conflict.heldBy.address)\(printed): only additions pass. "
                           + "Take the entry's text with `ghidra_library_apply` and `take_text`, make the addition over it, "
                           + "name any label it prints with `ghidra_label`, and publish again. If the entry is the wrong one, propose this module's review with `ghidra_type_propose`")
        }
        return rows
    }
}
