import CodeAnalysis
import Foundation

extension GhidraHost {
    /// PEI or DXE, when the caller does not say: a TE image is a PEIM, and so,
    /// on a PC, is a 32-bit PE; a 64-bit one is a DXE driver
    /// (`code_artifact.guess_phase`).
    public enum Phase: String, Sendable {
        case pei, dxe
    }

    /// The image's machine: in the TE header, or in the PE header `e_lfanew`
    /// points at.
    static func machine(of blob: Data) -> UInt16? {
        let bytes = [UInt8](blob.prefix(0x1000))
        func u16(_ at: Int) -> UInt16? { at + 1 < bytes.count ? UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 : nil }
        if TEImage.isTE(blob) { return u16(2) }
        guard bytes.count > 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A else { return nil }
        let lfanew = Int(bytes[0x3C]) | Int(bytes[0x3D]) << 8 | Int(bytes[0x3E]) << 16 | Int(bytes[0x3F]) << 24
        return u16(lfanew + 4)
    }

    static func guessPhase(_ blob: Data) -> Phase {
        TEImage.isTE(blob) || machine(of: blob) == 0x14C ? .pei : .dxe
    }

    /// Step 1 of a module (§5.2): the import — a TE image as the PE it
    /// stands for — Ghidra's analysis and, with `uefi`, the UEFI pass, in one
    /// `analyzeHeadless` run that keeps the project; then `state.json`. A
    /// module that already has a project is left as it is.
    @discardableResult
    public func create(module blob: Data, name: String, source: ProjectState.Source? = nil,
                       phase: Phase? = nil, uefi: Bool = true,
                       progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ProjectState {
        let digest = SHA256Digest(data: blob)
        let project = self.project(digest)
        if project.exists { return try project.state() }
        // Ghidra refuses a project whose path has an element starting with ".".
        if project.folder.pathComponents.contains(where: { $0.hasPrefix(".") }) {
            throw GhidraHostError(.project, "\(project.folder.path): Ghidra refuses a project path with an element "
                                  + "starting with '.'")
        }
        let install = try ghidra()
        let kind: String
        let image: Data
        let programName: String
        if TEImage.isTE(blob) {
            do {
                image = try TEImage.convert(blob)
            } catch {
                throw GhidraHostError(.project, "\(name): \(error)", status: 422)
            }
            kind = "TE"
            programName = "\(name).pe"
        } else if blob.prefix(2) == Data("MZ".utf8) {
            image = blob
            kind = "PE32"
            programName = "\(name).efi"
        } else {
            throw GhidraHostError(.project, "\(name): neither a PE (MZ) nor a TE (VZ) image", status: 422)
        }
        let chosen = phase ?? Self.guessPhase(blob)
        var pass: (gdt: URL, guids: URL)?
        if uefi {
            let paths = try await UEFITypes.ensure(install: install, sources: configuration.sources,
                                                   progress: progress)
            pass = (paths.archive(bits32: Self.machine(of: blob) == 0x14C), paths.guidsTSV)
        }
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghidra-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let imageURL = work.appendingPathComponent(programName)
        try image.write(to: imageURL)

        progress("Ghidra: \(name) (analysis\(uefi ? ", UEFI names" : ""))")
        var arguments = [project.folder.path, GhidraProject.name, "-import", imageURL.path, "-overwrite",
                         "-scriptPath", configuration.sources.scripts.path]
        if let pass {
            arguments += ["-postScript", "ApplyUefi.java", pass.gdt.path, pass.guids.path, chosen.rawValue]
        }
        let log = project.folder.appendingPathComponent("analyze.log")
        let status = try Subprocess.run(install.analyzeHeadless, arguments, log: log, timeout: 1800,
                                        environment: install.environment)
        // A script that does not compile is skipped with an error in the log,
        // and the run still exits 0: a project without the UEFI pass would be
        // recorded as having had one.
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard status == 0, !text.contains("SCRIPT ERROR"),
              FileManager.default.fileExists(atPath: project.folder.appendingPathComponent("\(GhidraProject.name).gpr").path)
        else {
            let tail = text.split(separator: "\n").suffix(30).joined(separator: "\n")
            throw GhidraHostError(.project, "Ghidra failed (exit \(status)); log: \(log.path)\n\(tail)")
        }
        let state = ProjectState(
            schema: 1, project: UUID().uuidString.lowercased(),
            module: .init(sha256: digest.hex, size: blob.count, name: name, kind: kind,
                          phase: pass == nil ? nil : chosen.rawValue),
            program: programName,
            madeWith: .init(ghidra: install.version, types: pass == nil ? nil : UEFITypes.edk2Tag,
                            passes: pass == nil ? [] : ["ApplyUefi.java"]),
            source: source, archive: pass?.gdt.path, createdAt: Self.now(), reviewed: false, published: nil)
        try project.write(state)
        return state
    }
}
