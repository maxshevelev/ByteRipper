import Foundation
import HelpBook
import Localization

/// The one `UserDefaults` the app reads and writes.
///
/// Everything that keeps a preference goes through this rather than through
/// `UserDefaults.standard`, for one reason: the app suite runs the real app as
/// its test host. Every test that set a word size, a theme, a layout direction
/// or a fill pattern would otherwise be writing into the user's own settings —
/// and reading whatever the user had left there, which is a test that passes or
/// fails depending on the machine it runs on. The technical-debt note in
/// `Design/TODO.md` about a test that lands 4 pt out only in a full run suspects
/// exactly that kind of leftover.
///
/// Under a test run this is a suite of its own, wiped as the process starts, so
/// every run begins from the app's defaults and ends leaving nothing behind.
///
/// What this cannot cover on its own: the autosaves AppKit performs itself — a
/// window's frame, a split view's positions, a toolbar's configuration — which
/// go to `UserDefaults.standard` inside AppKit, keyed by the app's bundle
/// identifier, and take no seam. So the test host runs under its own identifier
/// (the `dev.maxik.ByteRipper.TestsHost` that `Scripts/run-tests.sh` sets via the
/// `BYTERIPPER_APP_BUNDLE_ID` build setting), which is a different sandbox
/// container and a different preferences domain: every write of a test run,
/// AppKit's included, lands in a throwaway domain, and nothing reaches the
/// user's own settings. The guard in `store` below is the backstop for a run
/// that forgets that override: a test host still wearing the real identifier
/// would write the user's settings the moment it ran, so it refuses to start at
/// all instead.
enum AppDefaults {
    /// The identifier the real, shipped app wears — what macOS keys its sandbox
    /// container and preferences domain by. Kept here (not only in `project.yml`)
    /// so the test-host guard below can name it without re-spelling the string.
    static let realHostIdentifier = "dev.maxik.DumpCompare"

    /// The suite a test run gets instead of the user's own settings.
    static let testSuiteName = "dev.maxik.DumpCompare.tests"

    static let store: UserDefaults = {
        // A test run must run under the test host's own identifier, or it
        // writes the user's real settings (AppKit's autosaves included) the
        // moment it runs. The override is the test runner's job (Xcode's scheme
        // cannot carry it), so a run that forgets it reaches here still wearing
        // the real identifier — fail loudly, before anything is written, rather
        // than let it dirty the user's settings. A normal run is never under
        // XCTest, so this check is a no-op for the shipped app.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           Bundle.main.bundleIdentifier == realHostIdentifier {
            fatalError(
                "AppDefaults: a test host is running under the real identifier "
                + "\'" + realHostIdentifier + "\', not the test host's own. "
                + "Run the suite through Scripts/run-tests.sh (it passes the "
                + "BYTERIPPER_APP_BUNDLE_ID override), or set that build setting "
                + "to a test-host identifier. Refusing to start so the run does "
                + "not write the user's own settings."
            )
        }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
              let suite = UserDefaults(suiteName: testSuiteName)
        else { return .standard }
        // A run starts from the app's own defaults, whatever the last one did.
        suite.removePersistentDomain(forName: testSuiteName)
        return suite
    }()

    /// Whether this process is running the test suite — the same question that
    /// decides `store` above, asked by the few places that have to behave
    /// differently under test for a reason other than a stored value.
    static var isUnderTest: Bool { store !== UserDefaults.standard }

    /// Points the words at the same store everything else here uses, and —
    /// under test — pins the language.
    ///
    /// The pin is not tidiness. The suite asserts on what the app *says*
    /// ("None", "Stub A", "Merge S1 into S0"), and the language a run comes
    /// out in would otherwise be the language of the Mac it runs on: the same
    /// suite would pass in Frankfurt and fail in Moscow, for no reason in the
    /// code. English is the language the keys are written in, so it is the one
    /// a test can assert against.
    ///
    /// Called once, as early as anything reads a word — before the menu bar is
    /// built.
    static func startLocalization() {
        Localization.defaults = store
        if isUnderTest {
            store.set(LanguageChoice.fixed(.english).storedValue, forKey: Localization.choiceKey)
        }
        Localization.reload()
        Help.reload()
    }
}
