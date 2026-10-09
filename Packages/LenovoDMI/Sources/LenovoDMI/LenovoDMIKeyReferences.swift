import Foundation

/// Which entries of the store a driver's code asks for — read off its bytes,
/// without disassembling it.
///
/// A driver asks `LENOVO_VARIABLE_PROTOCOL` for an entry by its 16-byte key,
/// and on the images examined the key reaches the call in one of three ways:
///
/// - **A constant** in the driver's data: the namespace and the type, 16
///   bytes in a row (`OneKeyRecovery`, `LfcMbvUid`).
/// - **Built on the stack** from immediates: `mov dword [frame+d], imm32`
///   four times — three for the namespace's first 12 bytes, the fourth for
///   its last two and the type (`InstallMsdm`: `…AB43 0100`, type `0x0001`).
/// - **Built with the type left open**: the last two namespace bytes as a word
///   (`mov word [frame+d], 0x43AB`), and the type then set byte by byte —
///   `mov byte [frame+d+2], lo`, `mov byte [frame+d+3], hi` — before each
///   call. `L05SmbiosOverride` reads ten entries this way, one after another.
///
/// A key a driver computes at run time from a register is not seen; what is
/// found is what the driver names by constant, which is most of them.
public enum LenovoDMIKeyReferences {
    /// The keys under `namespaces` that `code` names.
    public static func keys(in code: [UInt8], namespaces: [[UInt8]]) -> Set<LenovoDMIKey> {
        var found = Set<LenovoDMIKey>()
        for namespace in namespaces where namespace.count == LenovoDMIFormat.namespaceSize {
            found.formUnion(constants(in: code, namespace: namespace))
            found.formUnion(built(in: code, namespace: namespace))
        }
        return found
    }

    // MARK: - A constant

    private static func constants(in code: [UInt8], namespace: [UInt8]) -> Set<LenovoDMIKey> {
        var found = Set<LenovoDMIKey>()
        for start in occurrences(of: namespace, in: code) {
            let end = start + namespace.count
            guard end + 2 <= code.count else { continue }
            found.insert(LenovoDMIKey(namespace: namespace, type: LE.u16(code, end)))
        }
        return found
    }

    // MARK: - Built on the stack

    /// A store of an immediate into the frame: where its displacement byte is,
    /// how it addresses the frame, and where the immediate starts.
    private struct FrameStore {
        /// `0x45` for `[rbp+d8]`, `0x44` for `[rsp+d8]` (with a `0x24` SIB).
        var base: UInt8
        var displacement: UInt8
        var isWord: Bool
    }

    /// The store whose immediate starts at `immediate`, if the bytes before it
    /// are `C7 45 d` / `C7 44 24 d`, or the same after a `66` word prefix.
    private static func store(before immediate: Int, in code: [UInt8]) -> FrameStore? {
        // [rbp+d8]: C7 45 d imm
        if immediate >= 3, code[immediate - 3] == 0xC7, code[immediate - 2] == 0x45 {
            let word = immediate >= 4 && code[immediate - 4] == 0x66
            return FrameStore(base: 0x45, displacement: code[immediate - 1], isWord: word)
        }
        // [rsp+d8]: C7 44 24 d imm
        if immediate >= 4, code[immediate - 4] == 0xC7, code[immediate - 3] == 0x44,
           code[immediate - 2] == 0x24 {
            let word = immediate >= 5 && code[immediate - 5] == 0x66
            return FrameStore(base: 0x44, displacement: code[immediate - 1], isWord: word)
        }
        return nil
    }

    private static func built(in code: [UInt8], namespace: [UInt8]) -> Set<LenovoDMIKey> {
        var found = Set<LenovoDMIKey>()
        let third = Array(namespace[8..<12])
        let tail = Array(namespace[12..<14])
        for at in occurrences(of: third, in: code) {
            // The fourth store follows within a few instructions.
            let window = (at + 4)..<min(code.count - 2, at + 40)
            guard let immediate = window.first(where: {
                code[$0] == tail[0] && code[$0 + 1] == tail[1] && store(before: $0, in: code) != nil
            }), let store = store(before: immediate, in: code) else { continue }
            if !store.isWord {
                guard immediate + 4 <= code.count else { continue }
                found.insert(LenovoDMIKey(namespace: namespace, type: LE.u16(code, immediate + 2)))
            } else {
                found.formUnion(typesSetLater(after: immediate + 2, store: store, in: code)
                    .map { LenovoDMIKey(namespace: namespace, type: $0) })
            }
        }
        return found
    }

    /// The types written into the open slot after a word store — the low byte
    /// at `d+2`, the high byte at `d+3`, or both at once — each one a key the
    /// driver goes on to ask for. Read up to the function's end, or 1 KiB.
    private static func typesSetLater(after start: Int, store: FrameStore, in code: [UInt8]) -> [UInt16] {
        let low = store.displacement &+ 2
        let high = store.displacement &+ 3
        let prefix: [UInt8] = store.base == 0x45 ? [0x45] : [0x44, 0x24]
        var lo: UInt8 = 0, hi: UInt8 = 0
        var types: [UInt16] = []
        var at = start
        let end = min(code.count, start + 0x400)
        while at < end {
            // `ret` then padding: the function is over.
            if code[at] == 0xC3, at + 1 < end, code[at + 1] == 0xCC { break }
            // mov byte [frame+d], imm8
            if code[at] == 0xC6, matches(prefix, in: code, at: at + 1), at + 2 + prefix.count < end {
                let slot = code[at + 1 + prefix.count]
                let value = code[at + 2 + prefix.count]
                // The low byte is set once, to clear the slot, before the high
                // byte names each type in turn; a store to it alone is not yet
                // a key the driver asks for.
                if slot == low { lo = value }
                if slot == high { hi = value; types.append(UInt16(hi) << 8 | UInt16(lo)) }
            }
            // mov word [frame+d+2], imm16
            if code[at] == 0x66, at + 1 < end, code[at + 1] == 0xC7,
               matches(prefix, in: code, at: at + 2), at + 3 + prefix.count + 2 <= end,
               code[at + 2 + prefix.count] == low {
                lo = code[at + 3 + prefix.count]
                hi = code[at + 4 + prefix.count]
                types.append(UInt16(hi) << 8 | UInt16(lo))
            }
            at += 1
        }
        return types
    }

    private static func matches(_ bytes: [UInt8], in code: [UInt8], at: Int) -> Bool {
        at + bytes.count <= code.count && Array(code[at..<(at + bytes.count)]) == bytes
    }

    private static func occurrences(of pattern: [UInt8], in code: [UInt8]) -> [Int] {
        guard !pattern.isEmpty, code.count >= pattern.count else { return [] }
        var found: [Int] = []
        code.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start + pattern.count <= buffer.count,
                  let hit = memmem(base + start, buffer.count - start, pattern, pattern.count) {
                let offset = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                found.append(offset)
                start = offset + 1
            }
        }
        return found
    }
}
