import Foundation
import Localization

/// A module's dependency expression — the bytecode a PEI, DXE or MM driver
/// carries to say which PPIs or protocols must exist before the dispatcher
/// may call it (`Design/UEFI/UEFI_IMAGE_FORMAT.md` §6.5).
///
/// The section body is a postfix expression: `PUSH <GUID>` pushes whether that
/// PPI is installed, `AND`, `OR` and `NOT` combine the values, `TRUE` and
/// `FALSE` are literals, and `END` finishes it. A dependency expression is
/// evaluated by the PEI core or the DXE dispatcher, not by this app — what the
/// panel shows is the expression as written, not a verdict about the running
/// firmware.
///
/// The parser keeps every token and every problem it found, because a
/// dependency expression that does not parse is exactly what a bench wants to
/// see: an unknown opcode, an operand missing, or bytes after `END` are all
/// things a vendor's build can leave behind.
public struct DependencyExpression: Equatable, Sendable {
    /// Which dispatcher reads it: the section type says.
    public enum Kind: String, Equatable, Sendable {
        case pei, dxe, mm

        public init?(sectionType: UInt8) {
            switch sectionType {
            case 0x1B: self = .pei
            case 0x13: self = .dxe
            case 0x1C: self = .mm
            default: return nil
            }
        }

        /// The name the section type already uses, for a detail row or an
        /// agent that has the kind but not the section.
        public var title: String {
            switch self {
            case .pei: return "PEI"
            case .dxe: return "DXE"
            case .mm: return "MM"
            }
        }
    }

    /// One opcode, with the GUID a `PUSH` carries.
    public enum Operation: Equatable, Sendable {
        case push(EFIGUID)
        case and, or, not
        case always, never
        case end
        case before, after, sor
        /// An opcode nobody has defined. Kept with its number: it is the
        /// finding, not something to drop.
        case unknown(UInt8)

        /// The specification's spelling, which is what a table should show.
        public var name: String {
            switch self {
            case .push: return "PUSH"
            case .and: return "AND"
            case .or: return "OR"
            case .not: return "NOT"
            case .always: return "TRUE"
            case .never: return "FALSE"
            case .end: return "END"
            case .before: return "BEFORE"
            case .after: return "AFTER"
            case .sor: return "SOR"
            case .unknown(let code): return String(format: "0x%02X", code)
            }
        }

        /// The GUID of a `PUSH`, and nil for every other opcode.
        public var guid: EFIGUID? {
            if case .push(let guid) = self { return guid }
            return nil
        }
    }

    public struct Token: Equatable, Sendable {
        /// Where the opcode is, in the section body's space.
        public var offset: UInt64
        public var operation: Operation

        public init(offset: UInt64, operation: Operation) {
            self.offset = offset
            self.operation = operation
        }
    }

    /// Something the expression does not obey. A `.bytesAfterEnd` is a
    /// warning; the rest mean the expression cannot be read as the format
    /// says it should be.
    public enum Problem: Equatable, Sendable {
        case unknownOperation(UInt8, at: UInt64)
        case truncatedGUID(at: UInt64)
        case missingOperands(at: UInt64)
        case leftoverValues(Int)
        case missingEnd
        case bytesAfterEnd(Int)
        case prefixNotAtStart(Operation, at: UInt64)
        case prefixNotAllowed(Operation, at: UInt64)

        public var isStructural: Bool {
            if case .bytesAfterEnd = self { return false }
            return true
        }

        /// One sentence, for the detail row or an agent. The offsets and
        /// opcodes are the specification's own spellings.
        public func text(in language: AppLanguage) -> String {
            switch self {
            case .unknownOperation(let code, let at):
                return L("Unknown dependency operation %1$@ at %2$@.", in: language,
                         String(format: "0x%02X", code), hex(at))
            case .truncatedGUID(let at):
                return L("The dependency expression ends inside a GUID at %1$@.", in: language, hex(at))
            case .missingOperands(let at):
                return L("The dependency expression needs more operands at %1$@.", in: language, hex(at))
            case .leftoverValues(let count):
                return L("The dependency expression leaves values on the stack (%1$@).", in: language, "\(count)")
            case .missingEnd:
                return L("The dependency expression has no END.", in: language)
            case .bytesAfterEnd(let count):
                return L("The dependency expression has bytes after END (%1$@).", in: language, "\(count)")
            case .prefixNotAtStart(let operation, let at):
                return L("The dependency expression uses %1$@ at %2$@; it belongs only at its start.",
                         in: language, operation.name, hex(at))
            case .prefixNotAllowed(let operation, let at):
                return L("A PEI dependency expression cannot use %1$@ (at %2$@).",
                         in: language, operation.name, hex(at))
            }
        }
    }

    public let kind: Kind
    /// Every opcode in the order it was read, including the one this parser
    /// stopped at.
    public let tokens: [Token]
    public let problems: [Problem]

    /// The expression as a tree, when it read to exactly one value.
    private let root: Expression?
    /// The first `BEFORE`, `AFTER` or `SOR`, which is not part of the boolean
    /// expression but does change when the module is dispatched.
    private let prefix: Operation?

    public init(kind: Kind, bytes: [UInt8], offset: UInt64 = 0) {
        self.kind = kind
        var tokens: [Token] = []
        var problems: [Problem] = []
        var stack: [Expression] = []
        var prefix: Operation?
        var seenValue = false
        var broken = false
        var ended = false
        var index = 0

        // An empty body is the same statement as `TRUE`: no dependency.
        if bytes.isEmpty {
            self.tokens = []
            self.problems = []
            self.root = .constant(true)
            self.prefix = nil
            return
        }

        while index < bytes.count {
            let at = offset + UInt64(index)
            let code = bytes[index]
            switch code {
            case 0x02:
                guard index + 17 <= bytes.count else {
                    // No GUID to keep, and no opcode to pretend it was: the
                    // offset is the finding.
                    problems.append(.truncatedGUID(at: at))
                    broken = true
                    index = bytes.count
                    break
                }
                let guid = EFIGUID(bytes: Array(bytes[(index + 1)..<(index + 17)]))
                tokens.append(Token(offset: at, operation: .push(guid)))
                if !broken { stack.append(.guid(guid)) }
                seenValue = true
                index += 17

            case 0x03, 0x04:
                let operation: Operation = code == 0x03 ? .and : .or
                tokens.append(Token(offset: at, operation: operation))
                if !broken {
                    guard stack.count >= 2 else {
                        problems.append(.missingOperands(at: at))
                        broken = true
                        index += 1
                        continue
                    }
                    let right = stack.removeLast()
                    let left = stack.removeLast()
                    stack.append(code == 0x03 ? .and(left, right) : .or(left, right))
                }
                index += 1

            case 0x05:
                tokens.append(Token(offset: at, operation: .not))
                if !broken {
                    guard let operand = stack.popLast() else {
                        problems.append(.missingOperands(at: at))
                        broken = true
                        index += 1
                        continue
                    }
                    stack.append(.not(operand))
                }
                index += 1

            case 0x06, 0x07:
                let operation: Operation = code == 0x06 ? .always : .never
                tokens.append(Token(offset: at, operation: operation))
                if !broken { stack.append(.constant(code == 0x06)) }
                seenValue = true
                index += 1

            case 0x08:
                tokens.append(Token(offset: at, operation: .end))
                ended = true
                index += 1
                let rest = bytes[index...]
                let after = rest.filter { $0 != 0 }.count
                if after > 0 { problems.append(.bytesAfterEnd(after)) }
                index = bytes.count

            case 0x00, 0x01, 0x09:
                let operation: Operation = code == 0x00 ? .before : code == 0x01 ? .after : .sor
                tokens.append(Token(offset: at, operation: operation))
                if kind == .pei {
                    problems.append(.prefixNotAllowed(operation, at: at))
                } else if seenValue || prefix != nil {
                    problems.append(.prefixNotAtStart(operation, at: at))
                } else {
                    prefix = operation
                }
                index += 1

            default:
                tokens.append(Token(offset: at, operation: .unknown(code)))
                problems.append(.unknownOperation(code, at: at))
                broken = true
                index = bytes.count
            }
        }

        // A read that stopped at a broken opcode already says why it stopped;
        // a missing END on top of that would be the consequence, not a second
        // finding.
        if !ended && !broken {
            problems.append(.missingEnd)
        }
        if !broken, stack.count == 1 {
            self.root = stack[0]
        } else {
            self.root = nil
            if !broken, ended, stack.count > 1 {
                problems.append(.leftoverValues(stack.count))
            } else if !broken, ended, stack.isEmpty {
                problems.append(.missingOperands(at: offset + UInt64(bytes.count)))
            }
        }
        self.tokens = tokens
        self.problems = problems
        self.prefix = prefix
    }

    /// The PPIs the expression asks for, in the order first seen; duplicates
    /// say nothing more than the first.
    public var pushedGUIDs: [EFIGUID] {
        var seen: Set<EFIGUID> = []
        var guids: [EFIGUID] = []
        for token in tokens {
            if let guid = token.operation.guid, seen.insert(guid).inserted {
                guids.append(guid)
            }
        }
        return guids
    }

    /// A statement that always holds: `TRUE`, or a section with no bytes.
    public var isAlways: Bool {
        if case .constant(true)? = root { return true }
        return false
    }

    /// A statement that never holds: `FALSE`.
    public var isNever: Bool {
        if case .constant(false)? = root { return true }
        return false
    }

    /// Whether the expression has a problem that stops it being read as the
    /// format says. Bytes after `END` do not: they are padding by another name.
    public var isMalformed: Bool {
        problems.contains { $0.isStructural }
    }

    /// The expression in infix form, with a name for a GUID where one is
    /// known. Nil when the operator stack did not come down to one value.
    public func text(name: (EFIGUID) -> String? = { _ in nil }) -> String? {
        guard let root else { return nil }
        let body = render(root, parent: 0, name: name)
        guard let prefix else { return body }
        return "\(prefix.name) \(body)"
    }

    // MARK: - The tree

    private indirect enum Expression: Equatable, Sendable {
        case guid(EFIGUID)
        case constant(Bool)
        case not(Expression)
        case and(Expression, Expression)
        case or(Expression, Expression)

        var precedence: Int {
            switch self {
            case .or: return 1
            case .and: return 2
            case .not: return 3
            case .guid, .constant: return 4
            }
        }
    }

    private func render(_ expression: Expression, parent: Int,
                        name: (EFIGUID) -> String?) -> String {
        let precedence = expression.precedence
        let text: String
        switch expression {
        case .guid(let guid):
            text = name(guid) ?? guid.description
        case .constant(let value):
            text = value ? "TRUE" : "FALSE"
        case .not(let operand):
            text = "NOT " + render(operand, parent: precedence, name: name)
        case .and(let left, let right):
            text = render(left, parent: precedence, name: name) + " AND "
                + render(right, parent: precedence, name: name)
        case .or(let left, let right):
            text = render(left, parent: precedence, name: name) + " OR "
                + render(right, parent: precedence, name: name)
        }
        return precedence < parent ? "(\(text))" : text
    }
}

private func hex(_ value: UInt64) -> String {
    String(format: "0x%llX", value)
}
