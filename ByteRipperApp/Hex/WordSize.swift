import Foundation
import Localization

/// Display word size (§6): the hex dump groups its bytes into words of this
/// many bytes, separating words with spaces. One byte — today's byte-per-cell
/// dump — is the default. Persisted app-wide; both panes share it.
enum WordSize: Int, CaseIterable {
    case one = 1
    case two = 2
    case four = 4
    case eight = 8

    static let userDefaultsKey = "HexWordSize"

    /// Posted after `set(_:)` so open hex views re-lay out.
    static let didChangeNotification = Notification.Name("HexWordSizeDidChange")

    /// The currently selected word size, falling back to one byte.
    static var current: WordSize {
        WordSize(rawValue: AppDefaults.store.integer(forKey: userDefaultsKey)) ?? .one
    }

    /// How the size is named in the View menu and on the toolbar's menu button
    /// (§24.2): "1 Byte", "2 Bytes".
    ///
    /// One whole phrase per case rather than a number glued to a suffix:
    /// English has two plural forms here and Russian three, and «1 байт,
    /// 2 байта, 8 байт» cannot be reached from `rawValue` and an "s".
    var title: String {
        switch self {
        case .one: return L("1 Byte")
        case .two: return L("2 Bytes")
        case .four: return L("4 Bytes")
        case .eight: return L("8 Bytes")
        }
    }

    /// Persists `size` and notifies observers to re-lay out (§6).
    static func set(_ size: WordSize) {
        AppDefaults.store.set(size.rawValue, forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
