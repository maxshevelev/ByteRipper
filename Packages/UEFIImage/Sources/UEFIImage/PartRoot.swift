import Foundation

extension Parser {
    /// The whole source as the one node `known` was in the parent's tree
    /// (`UEFIRootLayout.node`).
    ///
    /// The bytes are read first as they would be on their own — the NVAR
    /// walk for a variable, the image scan for anything else — and a node of
    /// the same kind spanning all of them is the answer: an Acer DMI store or
    /// a GPNV store announces itself, and is read out of the padding the scan
    /// leaves. What the bytes do not announce — a descriptor's region, a
    /// range the flash device map names, a structure the FIT points at — is
    /// the node the parent knew, standing over whatever the bytes hold. A
    /// scan alone made every one of those a single padding row.
    func root(as known: UEFIRootLayout.Node) -> UEFINode {
        let all = reader.all
        let empty = Parser.defaultEmptyByte
        let read: [UEFINode]
        if known.kind == .nvarEntry {
            read = parseNvarStore(all, emptyByte: empty, probe: true, depth: 0) ?? []
        } else {
            read = parseTopLevel(all, depth: 0)
        }
        if var own = Self.first(in: read, where: { $0.kind == known.kind && $0.range == all }) {
            // The name and the GUID as the parent had them: an NVAR entry
            // takes both from the entry linking to it, and a GUID from the
            // table at the store's end — neither of which is in the part.
            own.name = known.name
            own.guid = known.guid ?? own.guid
            return own
        }

        let headerEnd = min(known.headerLength, reader.count)
        let body = headerEnd..<reader.count
        var children = known.isLeaf ? [] : Self.contents(of: read)
        if known.isLeaf {
            // As the parent had it: nothing under it.
        } else if body != all || !children.contains(where: Self.isClaimed) {
            let scanned = Self.contents(of: scanRawArea(body, emptyByte: empty, depth: 1))
            children = scanned.contains(where: Self.isClaimed) ? scanned : []
        }
        if children.isEmpty, !known.isLeaf {
            // The defaults a flash map's region keeps are NVRAM stores, which
            // no scan looks for.
            let stores = walkNvramVolumeBody(body, emptyByte: empty, depth: 1)
            if stores.contains(where: Self.isClaimed) { children = stores }
        }
        return UEFINode(
            kind: known.kind,
            subtype: known.subtype,
            name: known.name,
            guid: known.guid,
            header: 0..<headerEnd,
            body: body,
            isFixed: known.isFixed,
            isErased: children.isEmpty && reader.isFilled(all, with: empty),
            children: children
        )
    }

    /// Something a reader recognised, rather than bytes nobody claimed.
    private static func isClaimed(_ node: UEFINode) -> Bool {
        node.kind != .padding && node.kind != .freeSpace
    }

    /// What a reading of the bytes holds, without the rows that only wrap it:
    /// the image node a scan groups several finds under, and the one padding
    /// row a find inside padding is read out of.
    private static func contents(of nodes: [UEFINode]) -> [UEFINode] {
        guard nodes.count == 1, let only = nodes.first,
              only.kind == .uefiImage || (only.kind == .padding && !only.children.isEmpty)
        else { return nodes }
        return only.children
    }

    private static func first(in nodes: [UEFINode], where matches: (UEFINode) -> Bool) -> UEFINode? {
        for node in nodes {
            if matches(node) { return node }
            if let found = first(in: node.children, where: matches) { return found }
        }
        return nil
    }
}
