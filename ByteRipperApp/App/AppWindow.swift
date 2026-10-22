import Cocoa

/// Every window of the app: an `NSWindow` that turns an Escape no view took
/// into `cancelOperation:`, sent from the first responder up the chain.
///
/// That is what AppKit did itself up to macOS 26, and what the app's own
/// Escapes are built on — the Find bar closing from the dump, a raised
/// fragment panel folding into its pill, the Settings window closing. From
/// macOS 27 an Escape no view handles reaches the window as a bare key and
/// goes no further, so the command is sent here, once for every window,
/// rather than by each view that lets the key through.
class AppWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == 53, modifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }
        (firstResponder ?? self).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    }
}
