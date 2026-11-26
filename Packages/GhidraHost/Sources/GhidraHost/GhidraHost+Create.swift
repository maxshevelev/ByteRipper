import CodeAnalysis
import ECImage
import Foundation

extension GhidraHost {
    /// PEI or DXE, when the caller does not say: a TE image is a PEIM, and so,
    /// on a PC, is a 32-bit PE; a 64-bit one is a DXE driver.
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

    /// A module's identity from the bytes it is opened by: their SHA-256, or
    /// for an EC image the SHA-256 of its image with the bytes the EC
    /// rewrites normalised (`ECFirmware`) — a BIOS copy and a chip read of
    /// one firmware are one module.
    public static func moduleDigest(of blob: Data) -> SHA256Digest {
        if ECFirmware.isEC(blob), let firmware = try? ECFirmware(slice: blob),
           let digest = SHA256Digest(hex: firmware.sha256) {
            return digest
        }
        return SHA256Digest(data: blob)
    }

    /// Whether the bytes are an image a module is made of: a PE (MZ), a TE
    /// (VZ), or an EC firmware image of a known family.
    public static func isModuleImage(_ blob: Data) -> Bool {
        blob.count > 2 && (blob.prefix(2) == Data("MZ".utf8) || blob.prefix(2) == Data("VZ".utf8)
                           || ECFirmware.isEC(blob))
    }

    /// The name an EC image's module gets (its version string); nil for
    /// anything else.
    public static func ecModuleName(_ blob: Data) -> String? {
        ECFirmware.isEC(blob) ? (try? ECFirmware(slice: blob))?.moduleName : nil
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
        let digest = Self.moduleDigest(of: blob)
        let project = self.project(digest)
        if !project.exists { try await restoreProject(digest) }
        if project.exists { return try project.state() }
        if ECFirmware.isEC(blob) {
            return try await createEC(blob, digest: digest, project: project, name: name, source: source,
                                      progress: progress)
        }
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
            throw GhidraHostError(.project, "\(name): neither a PE (MZ), a TE (VZ) nor an EC firmware image",
                                  status: 422)
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
                          phase: pass == nil ? nil : chosen.rawValue,
                          bits: Self.machine(of: blob) == 0x14C ? 32 : 64),
            program: programName,
            madeWith: .init(ghidra: install.version, types: pass == nil ? nil : UEFITypes.types,
                            passes: pass == nil ? [] : ["ApplyUefi.java"]),
            source: source, archive: pass?.gdt.path, createdAt: Self.now(), reviewed: false, published: nil)
        try project.write(state)
        return state
    }
}

extension GhidraHost {
    /// The pass an EC module is made with (`Skills/ghidra-uefi/scripts`):
    /// its blocks before the analysis, then the vectors, the interrupt
    /// dispatch and the registers named.
    static let ecPass = "ApplyItEc.java"

    /// Labels a probe of one firmware found and the code does not derive:
    /// by the module's identity, so they never land on another image. The
    /// per-pin descriptor tables of `ITE8380-EC-V0.00` (strides 0x2C and
    /// 0x20), left untyped.
    static let ecKnownLabels: [String: [(name: String, address: Int)]] = [
        "889159a794a3015e5547312b224db1f43c76daeddb90069ee856e32b6eac2b39": [
            ("PinDescTable_A", 0x239F8), ("PinDescTable_B", 0x23AD4)
        ]
    ]

    /// An EC firmware image made a module: [0, extent) normalised, imported
    /// raw at the family's flash base as its language, the EC pass run
    /// before Ghidra's analysis (`-preScript`), no EDK2 types.
    func createEC(_ blob: Data, digest: SHA256Digest, project: GhidraProject, name: String,
                  source: ProjectState.Source?, progress: @escaping @Sendable (String) -> Void) async throws
        -> ProjectState {
        let firmware: ECFirmware
        do {
            firmware = try ECFirmware(slice: blob)
        } catch {
            throw GhidraHostError(.project, "\(name): \(error)", status: 422)
        }
        if project.folder.pathComponents.contains(where: { $0.hasPrefix(".") }) {
            throw GhidraHostError(.project, "\(project.folder.path): Ghidra refuses a project path with an element "
                                  + "starting with '.'")
        }
        let install = try ghidra()
        let family = firmware.family
        let programName = "\(name).bin"
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghidra-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let imageURL = work.appendingPathComponent(programName)
        try firmware.image.write(to: imageURL)
        let layoutURL = work.appendingPathComponent("ec-layout.json")
        var passInput = try Self.ecPassInput(firmware, reference: configuration.ecReference)
        if ecCreatesAsBefore866, var object = try JSONSerialization.jsonObject(with: passInput) as? [String: Any] {
            object["refs_past_extent"] = nil
            // Nor the eflash_data block, which ApplyItEc makes only up to
            // host_update_size.
            object["host_update_size"] = nil
            passInput = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        }
        try passInput.write(to: layoutURL)

        progress("Ghidra: \(name) (EC, analysis)")
        let arguments = [project.folder.path, GhidraProject.name, "-import", imageURL.path, "-overwrite",
                         "-processor", family.language, "-loader", "BinaryLoader",
                         "-loader-baseAddr", String(format: "0x%llX", family.flashBase),
                         "-scriptPath", configuration.sources.scripts.path,
                         "-preScript", Self.ecPass, layoutURL.path,
                         // The eflash_data block, after the analysis (ApplyItEc `post`).
                         "-postScript", Self.ecPass, layoutURL.path, "post"]
        let log = project.folder.appendingPathComponent("analyze.log")
        let status = try Subprocess.run(install.analyzeHeadless, arguments, log: log, timeout: 1800,
                                        environment: install.environment)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard status == 0, !text.contains("SCRIPT ERROR"), text.contains("ApplyItEc done"),
              FileManager.default.fileExists(atPath: project.folder.appendingPathComponent("\(GhidraProject.name).gpr").path)
        else {
            let tail = text.split(separator: "\n").suffix(30).joined(separator: "\n")
            throw GhidraHostError(.project, "Ghidra failed (exit \(status)); log: \(log.path)\n\(tail)")
        }
        let facts = ECModuleFacts(
            family: family.id, extent: firmware.extent, extentSource: firmware.extentSource.rawValue,
            sliceSize: firmware.sliceSize, rawSHA256: firmware.rawSHA256,
            masked: firmware.masked.map { .init(offset: $0.offset, actual: Int($0.actual), normalised: Int($0.normalised)) },
            chipRead: firmware.chipRead, hostUpdateSize: family.hostUpdateSize, version: firmware.version,
            refsPastExtent: ecCreatesAsBefore866 ? nil
                : firmware.referencesPastExtent.map { .init(address: $0.address, from: $0.from) })
        let state = ProjectState(
            schema: 1, project: UUID().uuidString.lowercased(),
            module: .init(sha256: digest.hex, size: firmware.extent, name: name, kind: "EC", phase: nil, bits: 32,
                          ec: facts),
            program: programName,
            madeWith: .init(ghidra: install.version, types: nil, passes: [Self.ecPass]),
            source: source, archive: nil, createdAt: Self.now(), reviewed: false, published: nil)
        try project.write(state)
        return state
    }

    /// What the EC pass's flash references read (`ApplyItEc.flashReferences`),
    /// at creation and in `ecReapply` alike: the extent, the size a host
    /// update rewrites, and the references past the extent.
    static func ecFlashReferenceInput(_ firmware: ECFirmware) -> [String: Any] {
        ["extent": firmware.extent,
         "host_update_size": firmware.family.hostUpdateSize,
         "refs_past_extent": firmware.referencesPastExtent.map { ["address": $0.address, "from": $0.from] }]
    }

    /// What the EC pass reads: the family's memory map, the layout read from
    /// the image, and the register and interrupt maps of the family.
    static func ecPassInput(_ firmware: ECFirmware, reference: URL?) throws -> Data {
        let family = firmware.family
        var input: [String: Any] = ecFlashReferenceInput(firmware)
        input.merge([
            "family": family.id,
            "flash_base": family.flashBase,
            "ram": [family.ram.lowerBound, family.ram.upperBound],
            "regs": [family.registers.lowerBound, family.registers.upperBound],
            "signature": family.signatureForm(of: firmware.image) == 2 ? family.textSignatureOffset : family.signatureOffset,
            "version": family.signatureForm(of: firmware.image) == 2 ? family.textSignatureOffset : family.versionOffset,
            // The printable run the family reads as the version: the datum
            // is exactly that long, so it never covers the code after it.
            "version_length": family.version(of: firmware.image)?.utf8.count ?? 0,
            "known_labels": (ecKnownLabels[firmware.sha256] ?? []).map { ["name": $0.name, "address": $0.address] }
        ]) { _, new in new }
        input["layout"] = try JSONSerialization.jsonObject(with: try firmware.layout.json())
        if let reference {
            let registers = reference.appendingPathComponent("it83xx-registers.tsv")
            let irqs = reference.appendingPathComponent("it83xx-irqs.tsv")
            guard FileManager.default.fileExists(atPath: registers.path) else {
                throw GhidraHostError(.install, "\(registers.path): the EC register map is missing")
            }
            let map = try ECRegisterMap(tsv: String(contentsOf: registers, encoding: .utf8))
            input["registers"] = map.registers.map { register -> [String: Any] in
                var row: [String: Any] = ["name": register.name, "address": register.address, "width": register.width,
                                          "block": register.block, "source": register.source]
                if let note = register.description { row["description"] = note }
                if let status = register.status { row["status"] = status }
                return row
            }
            if FileManager.default.fileExists(atPath: irqs.path) {
                let names = try ECInterruptMap(tsv: String(contentsOf: irqs, encoding: .utf8))
                input["irq_sources"] = Dictionary(uniqueKeysWithValues: names.names.keys.compactMap { irq in
                    names.source(of: irq).map { (String(irq), $0) }
                })
            }
        }
        return try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted])
    }
}
