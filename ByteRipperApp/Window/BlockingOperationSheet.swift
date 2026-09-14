import Cocoa

/// A sheet for a long operation that has to run to its end with its window left
/// alone: what is being done, how far it has got, and a Cancel.
///
/// The status bar's strip (`OperationStatusView`) is for work that runs beside
/// the reader — a search, an index — and is easy to miss. This is for work whose
/// result depends on the window not being used while it runs: an update that
/// reads a document, works for seconds, and writes back into it. A sheet is
/// modal to its window, so nothing can be typed into that document meanwhile
/// and no second change can land under the first.
///
/// It is driven by the same `BackgroundOperation` the strip is: `rename` sets
/// the line under the title, `report` moves the bar, `finish` closes the
/// sheet, and Cancel calls the operation's own cancellation — whose owner
/// stops the work and finishes the operation, which closes the sheet too.
@MainActor final class BlockingOperationSheet: NSViewController {
    let titleLabel = NSTextField(labelWithString: "")
    /// What the operation is doing now.
    let phaseLabel = NSTextField(wrappingLabelWithString: "")
    let progressBar = NSProgressIndicator()
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let operation: BackgroundOperation

    private static let width: CGFloat = 380

    init(title: String, operation: BackgroundOperation) {
        self.operation = operation
        super.init(nibName: nil, bundle: nil)
        titleLabel.stringValue = title
        phaseLabel.stringValue = operation.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `operation` as a sheet on `controller`'s window, and hands the
    /// sheet back. The sheet closes itself when the operation finishes.
    @discardableResult
    static func present(_ operation: BackgroundOperation, title: String,
                        from controller: NSViewController) -> BlockingOperationSheet {
        let sheet = BlockingOperationSheet(title: title, operation: operation)
        controller.presentAsSheet(sheet)
        return sheet
    }

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        phaseLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        phaseLabel.textColor = .secondaryLabelColor
        phaseLabel.maximumNumberOfLines = 2
        phaseLabel.preferredMaxLayoutWidth = Self.width

        progressBar.style = .bar
        progressBar.isIndeterminate = operation.isIndeterminate
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = operation.progress
        if operation.isIndeterminate { progressBar.startAnimation(nil) }

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        let buttons = NSStackView(views: [NSView(), cancelButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, phaseLabel, progressBar, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: progressBar)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: Self.width),
            phaseLabel.widthAnchor.constraint(equalToConstant: Self.width),
            progressBar.widthAnchor.constraint(equalToConstant: Self.width),
            buttons.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        // A concrete frame so `presentAsSheet` sizes the sheet before layout.
        content.frame = NSRect(x: 0, y: 0, width: Self.width + 40, height: 140)
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        operation.onRename = { [weak self] name in self?.phaseLabel.stringValue = name }
        operation.onProgress = { [weak self] fraction in self?.progressBar.doubleValue = fraction }
        operation.onFinish = { [weak self] in self?.close() }
        // Finished before the sheet was up: nothing left to show.
        if !operation.isActive { close() }
    }

    @objc private func cancelPressed() {
        cancelButton.isEnabled = false
        phaseLabel.stringValue = "Cancelling…"
        operation.cancel()
    }

    private func close() {
        guard presentingViewController != nil else { return }
        presentingViewController?.dismiss(self)
    }
}
