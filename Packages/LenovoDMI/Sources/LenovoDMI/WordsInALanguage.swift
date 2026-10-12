import Localization

// A word this target says is put into words by whoever shows it, in that
// reader's language — a sentence (`LocalizedText`), or a word asked for in a
// named language (`L(_:in:)`). One in the app's language here would reach an
// agent, which reads English, in Russian; so the app's-language forms are
// unavailable in this target, and the compiler finds the one that slips in.

@available(*, unavailable, message: "say it as LocalizedText, or ask for it in a named language")
func L(_ key: String) -> String { fatalError() }

@available(*, unavailable, message: "say it as LocalizedText, or ask for it in a named language")
func L(_ key: String, _ arguments: Any...) -> String { fatalError() }

@available(*, unavailable, message: "say it as LocalizedText, or ask for it in a named language")
func L(_ key: String, context: String) -> String { fatalError() }
