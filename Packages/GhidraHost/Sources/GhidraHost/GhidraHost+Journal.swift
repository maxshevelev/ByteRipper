import CodeAnalysis
import Foundation

/// A publish as one transaction. What the owner gives and what the registry
/// decides is gathered first, and nothing is written until the decision is
/// yes; then the journal goes down, with everything the publish will write,
/// and the steps follow, each marked in it as it is done and each safe to do
/// again. The store's steps need nothing but the store: a server that stopped
/// part way finishes them when it starts. The owner's steps — the marks in
/// the project, the bytes the registry learns from it, the review's types,
/// `state.json`, the kept project — need the module's owner, and are finished
/// the next time the module is opened. The last step removes the journal.
struct PublishJournal: Codable, Sendable {
    enum Step: String, Codable, CaseIterable, Sendable {
        // The store's.
        case library, code, revision, sources, equates, analysis, typeVersion
        // The owner's.
        case marks, bytes, types, state, project

        var isStore: Bool { Self.store.contains(self) }
        static let store: [Step] = [.library, .code, .revision, .sources, .equates, .analysis, .typeVersion]
        static let owner: [Step] = [.marks, .bytes, .types, .state, .project]
    }

    var schema = 1
    var id: String
    var module: SHA256Digest
    var by: String?
    var startedAt: String
    /// The revision this publish would be, as the registry is told before the
    /// store records it.
    var planned: Int
    var reviewed: Bool
    var takeTypeConflicts: Bool
    var take: LibraryTake
    var offered: [LibraryProposal]
    /// The owner's export, its review document and its module description, as
    /// objects: the steps read them from the store.
    var exported: SHA256Digest
    var document: SHA256Digest
    var description: SHA256Digest
    var identity: ModuleIdentity
    var recipe: AnalysisRecipe
    var source: SourceIdentity
    var replace: Bool
    /// The shared types' conflicts as the export's dry merge found them; the
    /// merge step's answer replaces them.
    var typeConflicts: [String]
    var typeConflictsTaken: [String]
    var typeConflictOrigins: [String: String]
    /// The shared types' next version, decided before the journal went down,
    /// and its pointer size; nil when the merge changed nothing.
    var typesBits: String?
    var typesVersion: TypeArchiveVersion?
    /// Merged by the owner after the registry's decision, into the archive
    /// beside the projects: a store that keeps no versions.
    var typesInOwner: Bool?
    /// The agreed type proposals this publish applies (`TypeProposalBook`).
    var typeProposals: [String]?
    /// Every object the journal names, for `gc` to keep while it is there.
    var objects: [SHA256Digest] = []

    var done: [Step] = []
    var library: LibraryWriteResult?
    var libraryError: String?
    var typesError: String?
    /// The marks the project gets, as the owner's `/v1/library/mark` takes them.
    var marks: Data?
    /// The export with the registry's decisions written in, and the artifact
    /// the module stores.
    var decided: SHA256Digest?
    var stored: SHA256Digest?
    var review: SHA256Digest?
    var described: SHA256Digest?
    var rev: Int?
    var manifest: AnalysisManifest?
    var project: ProjectRecord?
    var projectError: String?

    func did(_ step: Step) -> Bool { done.contains(step) }

    var storeDone: Bool { Step.store.allSatisfy(did) }

    mutating func keep(_ object: SHA256Digest?) {
        if let object, !objects.contains(object) { objects.append(object) }
    }

    var reading: AnalysisReading? {
        guard reviewed, let rev, let review else { return nil }
        return AnalysisReading(rev: rev, review: review, description: described)
    }
}

/// Where a test stops a publish: after a step's writes, with the journal
/// marking it done or — as a crash between the two would leave it — not.
struct PublishStop: Equatable, Sendable {
    var step: PublishJournal.Step
    var marked: Bool
}

struct PublishStopped: Error, CustomStringConvertible {
    var stop: PublishStop
    var description: String {
        "the publish was stopped after its \(stop.step.rawValue) step, " + (stop.marked ? "marked" : "not marked")
    }
}

extension GhidraHost {
    func writeDown(_ journal: PublishJournal) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await writer.writeJournal(id: journal.id, data: try encoder.encode(journal))
    }

    /// A step done: marked in the journal, and the test's stop, if it is this one.
    func mark(_ step: PublishJournal.Step, in journal: inout PublishJournal) async throws {
        if let stop = publishStop, stop.step == step, !stop.marked {
            publishStop = nil
            throw PublishStopped(stop: stop)
        }
        if !journal.did(step) { journal.done.append(step) }
        try await writeDown(journal)
        if let stop = publishStop, stop.step == step {
            publishStop = nil
            throw PublishStopped(stop: stop)
        }
    }

    /// The store's steps not yet done, from the journal alone.
    func applyStoreSteps(_ journal: inout PublishJournal) async throws {
        let module = journal.module
        if !journal.did(.library) {
            var raw = try await writer.readObject(journal.exported)
            if journal.reviewed, !journal.offered.isEmpty {
                let written = try await writer.writeLibraryEntries(
                    module: module, rev: journal.planned, by: journal.by, proposals: journal.offered,
                    take: journal.take)
                journal.library = written
                // A store older than take_ids ignores them and answers with
                // the conflict: say which entries were not taken, rather
                // than let the publish read as if it had taken them.
                let missed = journal.take.ids.intersection(Set(written.conflicts.map(\.id)))
                if !missed.isEmpty {
                    journal.libraryError = "the store did not take " + missed.sorted().joined(separator: ", ")
                        + ": its server predates take_ids"
                }
                let marks = Self.libraryMarks(journal.offered, result: written,
                                              index: try await writer.readLibraryIndex())
                var entries: [String: String] = [:]
                for mark in marks {
                    if let address = mark["address"] as? String, let id = mark["id"] as? String { entries[address] = id }
                }
                raw = ModuleFormat.decided(raw, entries: entries)
                journal.marks = marks.isEmpty ? nil : try JSONSerialization.data(withJSONObject: ["items": marks])
            }
            let decided = try await writer.writeObject(raw)
            journal.decided = decided
            journal.keep(decided)
            try await mark(.library, in: &journal)
        }
        guard let decided = journal.decided else { throw GhidraHostError(.owner, "the journal names no decided export") }
        if !journal.did(.code) {
            // The registry takes each body's ASM from here, and every module
            // holding the body links to it at once.
            if journal.reviewed,
               let taught = try await teachEntryCode(module, artifact: try await writer.readObject(decided),
                                                     rev: journal.planned, by: journal.by) {
                if let relinked = taught.relinked {
                    var answer = journal.library ?? LibraryWriteResult()
                    answer.relinked = (answer.relinked ?? []) + relinked
                    journal.library = answer
                }
                if let error = taught.relinkError { journal.libraryError = error }
            }
            try await mark(.code, in: &journal)
        }
        if !journal.did(.revision) {
            // What a module stores is its own facts: the text of a registry
            // function is the entry's.
            let first = await Self.stored(try await writer.readObject(decided), writer: writer)
            let code = try await writer.writeObject(first.artifact)
            journal.stored = code
            journal.keep(code)
            if journal.reviewed {
                let document = try await writer.readObject(journal.document)
                let review = try await writer.writeObject(ModuleFormat.review(document, of: first))
                journal.review = review
                journal.keep(review)
                let description = try await writer.readObject(journal.description)
                journal.described = description.isEmpty ? nil : try await writer.writeObject(description)
                // The code goes into the store before the revision that names
                // it: a revision without its artifact is one nobody can diff.
                // The store numbers it: the last one again when nothing changed.
                journal.rev = try await writer.writeRevision(
                    module: module, reading: AnalysisReading(rev: journal.planned, review: review,
                                                             description: journal.described),
                    artifact: code, by: journal.by)
            }
            try await mark(.revision, in: &journal)
        }
        if !journal.did(.sources) {
            // What the registry was given — entries, their code — names the
            // revision this publish would have been; the store kept the last
            // one, unchanged, so it names that.
            if let rev = journal.rev, rev != journal.planned {
                try await writer.renumberLibrarySources(module: module, from: journal.planned, to: rev)
            }
            try await mark(.sources, in: &journal)
        }
        if !journal.did(.equates) {
            if journal.reviewed, let rev = journal.rev {
                do {
                    try await teachEntryEquates(module, artifact: try await writer.readObject(journal.exported),
                                                rev: rev, by: journal.by)
                } catch {
                    journal.libraryError = "\(error)"
                }
            }
            try await mark(.equates, in: &journal)
        }
        if !journal.did(.analysis) {
            guard let stored = journal.stored else { throw GhidraHostError(.owner, "the journal names no stored artifact") }
            journal.manifest = try await writer.writeAnalysis(
                module: journal.identity, recipe: journal.recipe, artifact: try await writer.readObject(stored),
                source: journal.source, reading: journal.reading, replace: journal.replace)
            try await mark(.analysis, in: &journal)
        }
        if !journal.did(.typeVersion) {
            // The shared types' next version, naming the revision that made it;
            // then the copy the owners read.
            if var version = journal.typesVersion, let bits = journal.typesBits {
                version.rev = journal.rev
                _ = try await writer.writeTypeArchive(bits: bits, version: version)
                try? await refreshArchiveCopy(bits: bits)
            }
            try await mark(.typeVersion, in: &journal)
        }
    }

    /// The owner's steps not yet done. A failure of one is reported in the
    /// publication: what the store holds is the revision either way, and the
    /// next publish gives the owner the same again.
    func applyOwnerSteps(_ journal: inout PublishJournal, record: OwnerRecord) async throws {
        let module = journal.module
        let project = self.project(module)
        if !journal.did(.marks) {
            if let marks = journal.marks {
                do {
                    _ = try await write(module, "/v1/library/mark", body: marks, byHost: true)
                } catch {
                    journal.libraryError = "\(error)"
                }
            }
            try await mark(.marks, in: &journal)
        }
        if !journal.did(.bytes) {
            if journal.reviewed, let rev = journal.rev {
                do {
                    try await teachEntryBytes(module, rev: rev, by: journal.by)
                } catch {
                    journal.libraryError = "\(error)"
                }
            }
            try await mark(.bytes, in: &journal)
        }
        if !journal.did(.types), journal.typesInOwner ?? true {
            // The review's types into the shared archive beside the projects,
            // now that the registry has said yes: a store that keeps versions
            // has had them decided and kept already.
            let path = journal.takeTypeConflicts ? "/v1/types/merge?take_type_conflicts=1" : "/v1/types/merge"
            do {
                let answer = try JSONSerialization.jsonObject(with: try await write(module, path, body: Data("{}".utf8), byHost: true))
                    as? [String: Any] ?? [:]
                journal.typeConflicts = answer["conflicts"] as? [String] ?? []
                journal.typeConflictsTaken = answer["taken"] as? [String] ?? []
                journal.typeConflictOrigins = answer["origins"] as? [String: String] ?? [:]
            } catch {
                journal.typesError = "\(error)"
            }
            try await mark(.types, in: &journal)
        } else if !journal.did(.types) {
            try await mark(.types, in: &journal)
        }
        if !journal.did(.state) {
            guard let manifest = journal.manifest else { throw GhidraHostError(.owner, "the journal names no analysis") }
            var state = try project.state()
            // The number the program stood at when this publish stored it: a
            // later one is a write the store has not got. Read after the marks,
            // which save the program themselves.
            let hello = (try? await Self.call(record.port, "GET", "/v1/hello", timeout: 10).data)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let number = hello.flatMap { $0["modification"] as? Int }
            let writes = hello.flatMap { $0["writes"] as? Int }
            // A publish that stored nothing new keeps its time: `at` says when
            // this revision was published, and a release with no writes
            // publishes none.
            let before = state.published
            let same = before?.artifact == manifest.artifact.sha256.hex && before?.recipe == journal.recipe.id
                && before?.review == journal.review?.hex && before?.description == journal.described?.hex
                && before?.rev == journal.reading?.rev
            state.published = .init(artifact: manifest.artifact.sha256.hex, recipe: journal.recipe.id,
                                    review: journal.review?.hex, description: journal.described?.hex,
                                    rev: journal.reading?.rev,
                                    at: same ? (before?.at ?? Self.now()) : Self.now(),
                                    modification: number, writes: writes)
            // What the module's own reading says: entries it only links are
            // the registry's review, not one of this module.
            let document = try await writer.readObject(journal.review ?? journal.document)
            let description = try await writer.readObject(journal.description)
            state.reviewed = journal.reviewed && Self.holdsOwnReview(document: document, description: description)
            try project.write(state)
            try await mark(.state, in: &journal)
        }
        if !journal.did(.project) {
            // The project is kept with the revision it published, last:
            // everything the owner writes for this publish is saved by now,
            // `state.json` too.
            if let reading = journal.reading, let stored = journal.stored {
                do {
                    journal.project = try await keepProject(module, state: try project.state(), rev: reading.rev,
                                                            artifact: stored, review: reading.review,
                                                            recipe: journal.recipe.id)
                    journal.projectError = nil
                } catch {
                    journal.projectError = "\(error)"
                }
            }
            try await mark(.project, in: &journal)
        }
    }

    /// The journals a stopped server left: their store steps done, before any
    /// route opens. Their owner steps wait for the module's next open. The
    /// count of journals found.
    @discardableResult
    public func recoverPublishes() async throws -> Int {
        let hold = try await writer.lockPublishes()
        publishing += 1
        defer {
            publishing -= 1
            hold.release()
        }
        var found = 0
        // A version kept before a stop and not yet copied beside the projects.
        await refreshArchiveCopies()
        for data in try await writer.readJournals() {
            var journal = try JSONDecoder().decode(PublishJournal.self, from: data)
            found += 1
            try await applyStoreSteps(&journal)
            unfinished.insert(journal.module)
        }
        return found
    }

    /// The owner's steps of the module's unfinished publishes, now that its
    /// owner runs; the journal goes when they are done.
    func finishPublishes(_ module: SHA256Digest, record: OwnerRecord) async {
        guard unfinished.contains(module), !finishing.contains(module), publishing == 0 else { return }
        finishing.insert(module)
        defer { finishing.remove(module) }
        do {
            let hold = try await writer.lockPublishes()
            publishing += 1
            defer {
                publishing -= 1
                hold.release()
            }
            for data in try await writer.readJournals() {
                var journal = try JSONDecoder().decode(PublishJournal.self, from: data)
                guard journal.module == module else { continue }
                try await applyStoreSteps(&journal)
                try await applyOwnerSteps(&journal, record: record)
                try await writer.removeJournal(id: journal.id)
                await noteProposalsApplied(journal.typeProposals ?? [], module: module, revision: journal.rev,
                                           version: journal.typesVersion?.version,
                                           relinked: journal.library?.relinked ?? [])
            }
            unfinished.remove(module)
        } catch {
            // Left for the next open: the journal says where it stopped.
        }
    }
}
