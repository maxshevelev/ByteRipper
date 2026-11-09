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

    /// The functions a registry answer does not take.
    public static func rows(of result: LibraryWriteResult) -> [Row] {
        var rows: [Row] = (result.notLibrary ?? []).map { row in
            let why: String
            switch row.why {
            case "data":
                why = "the registry refused it, it reads data no citation covers: "
                    + (row.data ?? []).joined(separator: ", ")
            case "callee":
                why = "the registry refused it, it calls what the registry does not hold: "
                    + (row.callees ?? []).joined(separator: ", ")
            case "dependency":
                why = "the registry refused it, it calls a library its own does not depend on: "
                    + (row.callees ?? []).joined(separator: ", ")
            case "library":
                why = "the registry refused it, it declares no such library"
            case "taken_out":
                why = "taken out of the registry" + (row.reason.map { ": \($0)" } ?? "")
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
                           + "name any label it prints with `ghidra_label`, and publish again. Replacing it is an administrator's decision")
        }
        return rows
    }
}
