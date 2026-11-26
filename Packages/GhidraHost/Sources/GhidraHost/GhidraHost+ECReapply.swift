import CodeAnalysis
import ECImage
import Foundation

/// What an EC module's creation adds for the flash past the image extent,
/// added to a project made before it did (builds before 866): the DATA
/// references from the code, the `FlashRef_<ADDR>` labels with their plates
/// (`ApplyItEc.flashReferences`, the same code creation runs), and
/// `refs_past_extent` in the module's facts. The register labels and the
/// plates of the single-interrupt ISRs the pass placed are brought to the
/// maps as they are now (`ApplyItEc.refreshNames`), unless a review changed
/// them. On a Ghidra whose language
/// carries nds32-standby-1, also the code a stock analysis never read after
/// each `standby`, and the bodies of the functions it cut
/// (`ApplyItEc.standbySites`). Nothing else of the review is touched, and a
/// second run adds and changes nothing.
extension GhidraHost {
    static let ecReapplyPath = "/v1/ec/reapply"

    /// The step, under the module's lease. The references are read from the
    /// image the program holds, made a slice again with the facts (the bytes
    /// the identity normalises put back, the rest of the slice erased), so
    /// they are the ones a creation from the dump reads; an image that does
    /// not come back to the module's identity and extent is refused.
    func ecReapply(_ module: SHA256Digest, holder: String?) async throws -> Data {
        try tellClosed(module, holder: holder)
        let project = self.project(module)
        guard project.exists else {
            throw GhidraHostError(.project, "\(module.hex) has no project", status: 404)
        }
        let state = try project.state()
        guard state.module.kind == "EC", let facts = state.module.ec else {
            throw GhidraHostError(.refused, "\(state.module.name) is a \(state.module.kind) module: "
                                  + "`ec/reapply` is for an EC module", status: 422)
        }
        try requireLease(module, holder: holder)
        let record = try await owner(of: module)
        let read = try await Self.call(record.port, "GET", "/v1/ec/image").data
        guard let object = try JSONSerialization.jsonObject(with: read) as? [String: Any],
              let text = object["base64"] as? String, let image = Data(base64Encoded: text) else {
            throw GhidraHostError(.project, "the owner sent no image of the flash block")
        }
        let firmware = try Self.ecFirmware(image: image, facts: facts)
        guard firmware.sha256 == module.hex, firmware.extent == facts.extent else {
            throw GhidraHostError(.refused, "the program's flash block does not read back as the module "
                                  + "(identity \(firmware.sha256), extent \(firmware.extent)): nothing was added",
                                  status: 409)
        }
        var input = Self.ecFlashReferenceInput(firmware)
        // The names: the register labels and ISR plates the pass placed,
        // refreshed from the maps as they are now (`ApplyItEc.refreshNames`).
        if let reference = configuration.ecReference {
            input.merge(try Self.ecMapInput(reference: reference)) { _, new in new }
            input["irq_handlers"] = firmware.layout.irqHandlers.map { ["number": $0.number, "target": $0.target] }
        }
        let body = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let answered = try await write(module, Self.ecReapplyPath, body: body, holder: holder, byHost: true)
        noteActivity(module, holder: holder, call: Self.callName(Self.ecReapplyPath), kind: .write)

        // The facts: added when missing. A write marks a module reviewed;
        // this one is no review, so the mark stays as it was.
        var after = try project.state()
        let references = firmware.referencesPastExtent.map { ECModuleFacts.FlashRef(address: $0.address, from: $0.from) }
        var factsAnswer: [String: Any]
        if after.module.ec?.refsPastExtent == nil {
            after.module.ec?.refsPastExtent = references
            factsAnswer = ["refs_past_extent": "added", "count": references.count]
        } else if after.module.ec?.refsPastExtent != references {
            // A list an earlier rule read (by value, not by use): the facts
            // are the image's, not the review's, so they follow the rule.
            let before = after.module.ec?.refsPastExtent?.count ?? 0
            after.module.ec?.refsPastExtent = references
            factsAnswer = ["refs_past_extent": "replaced", "count": references.count, "was": before]
        } else {
            factsAnswer = ["refs_past_extent": "kept", "count": references.count]
        }
        after.reviewed = state.reviewed
        try project.write(after)

        var answer = (try JSONSerialization.jsonObject(with: answered) as? [String: Any]) ?? [:]
        answer["facts"] = factsAnswer
        return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
    }

    /// The slice an EC module was made from, as far as the module tells it:
    /// its image with the bytes the identity normalises put back, and the
    /// rest of the slice erased. What `referencesPastExtent` reads of it — the
    /// image, the extent and the slice's size — is the dump's.
    static func ecFirmware(image: Data, facts: ECModuleFacts) throws -> ECFirmware {
        var slice = Data(image.prefix(facts.extent))
        for masked in facts.masked where masked.offset < slice.count {
            slice[masked.offset] = UInt8(truncatingIfNeeded: masked.actual)
        }
        if slice.count < facts.sliceSize {
            slice.append(Data(repeating: 0xFF, count: facts.sliceSize - slice.count))
        }
        do {
            return try ECFirmware(slice: slice)
        } catch {
            throw GhidraHostError(.project, "the program's image is no EC firmware image: \(error)", status: 422)
        }
    }
}
