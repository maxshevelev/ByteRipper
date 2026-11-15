import CodeAnalysis
import Foundation

/// EFIAPI is `__cdecl` on IA32, and the EDK2 archives before revision 3 gave
/// their function types no convention, which a 32-bit program of the windows
/// spec reads as `__stdcall`: every indirect call through a PEI service or a
/// PPI member then took its arguments off the stack, and the caller's stack
/// locals moved after it (issue 4a9a4484). Revision 3's archives carry the
/// convention. A 32-bit project made with an earlier one goes on with the
/// current archive, and the shared 32-bit review types get it in a version of
/// their own, so the program, the shared types and EDK2 agree.
extension GhidraHost {
    /// The revision a recipe's `types` names: `edk2-stable202608-r2` is 2, the
    /// tag alone is 1; nil for another tag.
    static func typesRevision(_ types: String) -> Int? {
        if types == UEFITypes.edk2Tag { return 1 }
        let prefix = UEFITypes.edk2Tag + "-r"
        guard types.hasPrefix(prefix) else { return nil }
        return Int(types.dropFirst(prefix.count))
    }

    /// Whether the project's program is 32-bit, as the archive it was typed
    /// with says, or the image's machine, or — a project that recorded
    /// neither — its phase. The phase alone is a guess: an X64 PEIM exists.
    static func typedIa32(_ state: ProjectState) -> Bool {
        if let archive = state.archive {
            let name = URL(fileURLWithPath: archive).lastPathComponent
            if name.hasPrefix("uefi_Ia32-") { return true }
            if name.hasPrefix("uefi_X64-") { return false }
        }
        if let bits = state.module.bits { return bits == 32 }
        return state.module.kind == "TE" || state.module.phase == "pei"
    }

    /// The state a project typed with an earlier revision opens with: the
    /// current archive in place of its own. The owner gives the program's
    /// function types the convention (revision 3, 32-bit) and its EDK2 enums
    /// their members' values (revision 4, issue 33a286ab) at open. Unchanged
    /// for a project of the current revision or of another tag.
    func retypedForCurrentArchive(_ project: GhidraProject, _ state: ProjectState) async throws -> ProjectState {
        guard let types = state.madeWith.types, types != UEFITypes.types,
              let revision = Self.typesRevision(types), revision < UEFITypes.typesRevision else { return state }
        let paths = try await UEFITypes.ensure(install: try ghidra(), sources: configuration.sources)
        var retyped = state
        retyped.madeWith.types = UEFITypes.types
        retyped.archive = paths.archive(bits32: Self.typedIa32(state)).path
        try project.write(retyped)
        return retyped
    }

    /// The shared review types of the module's size given the values EDK2's
    /// archive gives its enums' members (issue 33a286ab — an alias numbered
    /// as the member before it plus one) and its `BOOLEAN` and `INT8`
    /// (revision 5), once in this process, through the module's
    /// owner: a version of their own when anything changed.
    /// Under the publishes' hold. A failure is left for the next owner.
    func migrateSharedEDK2Enums(_ module: SHA256Digest) async {
        guard writer.keepsTypeArchives, let state = try? project(module).state() else { return }
        let bits = Self.typedIa32(state) ? "Ia32" : "X64"
        guard !sharedEDK2EnumsDone.contains(bits) else { return }
        do {
            let hold = try await writer.lockPublishes()
            defer { hold.release() }
            let (folder, current) = try await archiveWorkingCopy(bits: bits)
            defer { try? FileManager.default.removeItem(at: folder) }
            guard current != nil else {
                sharedEDK2EnumsDone.insert(bits)
                return
            }
            let answer = try JSONSerialization.jsonObject(with: try await typesCall(
                module, "/v1/types/edk2enums", body: try JSONSerialization.data(withJSONObject: ["archive": folder.path])))
                as? [String: Any] ?? [:]
            let changed = answer["changed"] as? Int ?? 0
            let scalars = answer["scalars"] as? Int ?? 0
            if changed > 0 {
                var reasons: [String] = []
                if changed > scalars {
                    reasons.append("EDK2 enum members initialised with another member's name take its value: "
                        + "\(changed - scalars) members (issue 33a286ab)")
                }
                if scalars > 0 {
                    reasons.append("BOOLEAN is the enum FALSE/TRUE and INT8 a signed byte, "
                        + "as EDK2 types revision 5 has them: \(scalars) types")
                }
                let merged = TypesMerged(Data(#"{"changed": true}"#.utf8))
                if let version = try await nextTypeVersion(
                    bits: bits, folder: folder, after: current, answer: merged, by: "server", module: module,
                    reason: reasons.joined(separator: "; ")) {
                    _ = try await writer.writeTypeArchive(bits: bits, version: version)
                    try? await refreshArchiveCopy(bits: bits)
                }
            }
            sharedEDK2EnumsDone.insert(bits)
        } catch {
            // The next owner of this size tries again.
        }
    }

    /// The shared 32-bit review types given the convention, once in this
    /// process, through the owner of a 32-bit module: a version of their own
    /// when any function type had none. Under the publishes' hold, so no
    /// publish decides on the archive in between. A failure is left for the
    /// next 32-bit owner this process starts.
    func migrateSharedEFIAPI(_ module: SHA256Digest) async {
        guard !sharedEFIAPIDone, writer.keepsTypeArchives, let state = try? project(module).state(),
              Self.typedIa32(state) else { return }
        do {
            let hold = try await writer.lockPublishes()
            defer { hold.release() }
            let bits = "Ia32"
            let (folder, current) = try await archiveWorkingCopy(bits: bits)
            defer { try? FileManager.default.removeItem(at: folder) }
            guard current != nil else {
                sharedEFIAPIDone = true
                return
            }
            let answer = try JSONSerialization.jsonObject(with: try await typesCall(
                module, "/v1/types/efiapi", body: try JSONSerialization.data(withJSONObject: ["archive": folder.path])))
                as? [String: Any] ?? [:]
            let changed = answer["changed"] as? Int ?? 0
            if changed > 0 {
                let merged = TypesMerged(Data(#"{"changed": true}"#.utf8))
                if let version = try await nextTypeVersion(
                    bits: bits, folder: folder, after: current, answer: merged, by: "server", module: module,
                    reason: "EFIAPI is __cdecl on IA32: \(changed) function types had no convention (issue 4a9a4484)") {
                    _ = try await writer.writeTypeArchive(bits: bits, version: version)
                    try? await refreshArchiveCopy(bits: bits)
                }
            }
            sharedEFIAPIDone = true
        } catch {
            // The next 32-bit owner tries again.
        }
    }
}
