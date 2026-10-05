import AppKit
import AVFoundation
import HelpUI
import Localization

/// The sound a node is, played under its rows the way a player plays it: a
/// button that plays and pauses, one that stops and goes back to the start,
/// a bar that shows how far it has got and moves it when dragged, and the
/// time played against the whole.
///
/// What it plays is a copy of the node's bytes, taken when the row was
/// selected: an edit to the dump while it plays does not reach it. It stops
/// when it leaves the window — another row selected, the panel closed — since
/// a sound that keeps playing for a row nobody is looking at is a sound
/// nobody can find to stop.
final class SoundPlayerView: NSView {
    private let player: AVAudioPlayer
    private let playButton = NSButton()
    private let stopButton = NSButton()
    private let bar = NSSlider()
    private let time = NSTextField(labelWithString: "")
    /// Moves the bar while the sound plays; nil while it does not.
    private var ticker: Timer?
    /// Says when the sound has played to its end. Kept here: the player holds
    /// its delegate weakly.
    private var finish: Finish?

    /// Nil when AVFoundation cannot read the bytes as a sound — the rows have
    /// said what the parser read, and there is nothing to play.
    init?(wav bytes: [UInt8]) {
        guard let player = try? AVAudioPlayer(data: Data(bytes), fileTypeHint: AVFileType.wav.rawValue),
              player.duration > 0
        else { return nil }
        self.player = player
        super.init(frame: .zero)
        player.prepareToPlay()
        let finish = Finish { [weak self] in self?.didFinish() }
        self.finish = finish
        player.delegate = finish

        let symbols = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        for button in [playButton, stopButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = symbols
            button.contentTintColor = .labelColor
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        playButton.action = #selector(playOrPause)
        stopButton.action = #selector(stop)
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: L("Stop"))
        ControlHelp.describe(stopButton, L("Stop"))

        bar.minValue = 0
        bar.maxValue = player.duration
        bar.isContinuous = true
        bar.controlSize = .small
        bar.target = self
        bar.action = #selector(seek)
        bar.translatesAutoresizingMaskIntoConstraints = false
        ControlHelp.describe(bar, name: L("Playback position"), tooltip: L("Drag to move through the sound"))

        time.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.translatesAutoresizingMaskIntoConstraints = false
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [playButton, stopButton, bar, time])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(4, after: playButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 22),
            stopButton.widthAnchor.constraint(equalToConstant: 22),
        ])
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Whether the sound is playing now — for the tests.
    var isPlaying: Bool { player.isPlaying }

    /// Where the sound is, in seconds — for the tests.
    var position: TimeInterval { player.currentTime }

    @objc func playOrPause() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        update()
    }

    @objc func stop() {
        player.stop()
        player.currentTime = 0
        update()
    }

    @objc private func seek() {
        player.currentTime = bar.doubleValue
        update()
    }

    private func didFinish() {
        player.currentTime = 0
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, player.isPlaying { stop() }
    }

    /// The buttons, the bar and the time, as the player now is; the ticker
    /// running only while it plays.
    private func update() {
        let playing = player.isPlaying
        let word = playing ? L("Pause") : L("Play")
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                   accessibilityDescription: word)
        ControlHelp.describe(playButton, word)
        if playing, ticker == nil {
            let ticker = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(ticker, forMode: .common)
            self.ticker = ticker
        } else if !playing {
            ticker?.invalidate()
            ticker = nil
        }
        tick()
    }

    /// A drag of the bar moves the player first (`seek`), so the bar set from
    /// the player is where the drag put it.
    private func tick() {
        bar.doubleValue = player.currentTime
        time.stringValue = "\(Self.clock(player.currentTime)) / \(Self.clock(player.duration))"
    }

    /// Minutes and seconds, as a player shows them.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// AVFoundation's delegate, apart from the view: it says the sound ended,
    /// on whatever thread the player chose.
    private final class Finish: NSObject, AVAudioPlayerDelegate {
        private let ended: @MainActor () -> Void

        init(_ ended: @escaping @MainActor () -> Void) {
            self.ended = ended
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            let ended = ended
            DispatchQueue.main.async { MainActor.assumeIsolated { ended() } }
        }
    }
}
