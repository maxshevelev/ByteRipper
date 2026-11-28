import CodeAnalysis
import Foundation
import Localization
import UEFIImage

// help: panel.uefi.ec-runtime-data
/// An EC chip read's run-time data as tables, one per area the module's
/// published review lists: a row per slot of a log, a column per field, and
/// under each table what the review says of the values the read holds. Every
/// word about a value is the review's (`ECFlashDataDecoder`); this only lays
/// them out.
public enum UEFIECRuntimeDetail {
    /// What the run-time data node shows: the decoded areas, or why there
    /// are none.
    public enum State: Equatable, Sendable {
        case decoded([ECFlashDataDecoder.Area])
        /// The store has no published review of this image's module.
        case noReview
    }

    public static func tables(_ state: State, image: NodeID? = nil, in language: AppLanguage) -> [UEFIDetailTable] {
        guard case .decoded(let areas) = state else {
            return [UEFIDetailTable(title: L("Run-time data", in: language), symbol: "list.bullet.rectangle",
                                    columns: [], rows: [],
                                    note: L("The module's published review is not available: the values are not decoded.",
                                            in: language))]
        }
        if areas.isEmpty {
            return [UEFIDetailTable(title: L("Run-time data", in: language), symbol: "list.bullet.rectangle",
                                    columns: [], rows: [],
                                    note: L("The module's review lists no flash data areas.", in: language))]
        }
        return areas.flatMap { [table($0, in: language)] + code($0, image: image, in: language) }
    }

    static func hex(_ value: UInt64, width: Int) -> String {
        String(format: "0x%0\(max(width, 1) * 2)llX", value)
    }

    static func table(_ area: ECFlashDataDecoder.Area, in language: AppLanguage) -> UEFIDetailTable {
        let title = "\(hex(UInt64(area.address), width: 0)) · \(area.format)"
        let fields = area.elements.first?.fields ?? []
        let isLog = area.elements.first?.index != nil
        var columns: [String] = []
        if isLog { columns.append(L("Slot", in: language)) }
        columns += fields.map(\.name)
        columns.append(L("Bytes", in: language))
        var rows: [[UEFIDetailTable.Cell]] = []
        var free = 0
        // The values the read holds, each explained once under the table.
        var explained: [String] = []
        var seen: Set<String> = []
        for element in area.elements {
            if element.free {
                free += 1
                continue
            }
            var row: [UEFIDetailTable.Cell] = []
            if let index = element.index { row.append(.init(String(index))) }
            for field in element.fields {
                let width = field.bits != nil ? 0 : 1
                var text = field.bits != nil ? String(field.value) : hex(field.value, width: width)
                if let member = field.member {
                    text += " " + member
                    let key = "\(field.type).\(member)"
                    if !seen.contains(key), let comment = field.memberComment {
                        seen.insert(key)
                        explained.append("\(member) (\(hex(field.value, width: 1))): \(comment)")
                    }
                } else if field.isEnum {
                    text += " — " + L("not in the review", in: language)
                }
                row.append(.init(text, isStrong: field.isEnum && field.member == nil))
            }
            row.append(.init(element.raw.map { String(format: "%02X", $0) }.joined(separator: " ")))
            rows.append(row)
        }
        var notes: [String] = []
        switch area.problem {
        case .pastTheEnd: notes.append(L("The area lies past the end of the read.", in: language))
        case .unknownType(let name):
            notes.append(String(format: L("The review defines no type %1$@.", in: language), name))
        case nil: break
        }
        if let meaning = area.meaning { notes.append(meaning) }
        if isLog, free > 0 { notes.append(String(format: L("Free slots: %1$@.", in: language), String(free))) }
        if area.erased { notes.append(L("Every byte is erased (FF).", in: language)) }
        for field in fields where field.comment != nil {
            notes.append("\(field.name): \(field.comment!)")
        }
        notes += explained
        if let confidence = area.confidence { notes.append(L("Confidence", in: language) + ": " + confidence) }
        return UEFIDetailTable(title: title, symbol: isLog ? "list.number" : "square.grid.3x1.below.line.grid.1x2",
                               columns: columns, rows: rows, linkColumn: -1,
                               note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    /// The code that writes and reads the area, the review's evidence: a
    /// row per address, which opens the code there.
    static func code(_ area: ECFlashDataDecoder.Area, image: NodeID?, in language: AppLanguage) -> [UEFIDetailTable] {
        let places = area.writers.map { (L("Writes", in: language), $0) } + area.readers.map { (L("Reads", in: language), $0) }
        guard !places.isEmpty else { return [] }
        let rows = places.map { [UEFIDetailTable.Cell($0.0), UEFIDetailTable.Cell($0.1)] }
        let targets: [UEFIDetailTable.Target?] = places.map { place in
            guard let image, let address = CodeAddress(hex: place.1) else { return nil }
            return .code(image: image, address: address.value)
        }
        return [UEFIDetailTable(title: String(format: L("Code of %1$@", in: language), hex(UInt64(area.address), width: 0)),
                                symbol: "chevron.left.forwardslash.chevron.right",
                                columns: [L("Access", in: language), L("Address", in: language)],
                                rows: rows, rowTargets: targets, linkColumn: 1)]
    }
}
