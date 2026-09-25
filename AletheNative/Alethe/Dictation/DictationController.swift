import AletheFoundation
import AletheTerminal
import AppKit
import AVFoundation
import Observation

/// Dictation (upstream PER-6, with Apple's on-device speech instead of Parakeet): ⌥⌘E pressed starts and
/// pressed again stops, held it stops on release; Esc cancels. Final text goes into what had focus when
/// it started — a terminal (typed, no Enter) or a text field — in the interface language.
@Observable
@MainActor
final class DictationController {
    private(set) var machine = DictationMachine()
    /// The words not final yet.
    private(set) var liveText = ""
    private(set) var downloadingModel = false
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var engine: DictationEngine?
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var lastInserted = ""
    @ObservationIgnored private var monitor: Any?
    /// The engine is listening (its start finished).
    @ObservationIgnored private var ready = false

    private enum Target {
        case terminal(TerminalPaneView)
        case text(NSTextInputClient)
    }

    func start(environment: AppEnvironment) {
        guard monitor == nil else { return }
        self.environment = environment
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// ⌥⌘E down/up, and Esc while dictating. (⌥⌘D is macOS's Dock hiding shortcut and never reaches the app.)
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.type == .keyDown, event.keyCode == 53, machine.isActive || machine.phase != .idle {
            apply(machine.escape())
            return true
        }
        guard event.charactersIgnoringModifiers?.lowercased() == "e", flags == [.command, .option] else { return false }
        if event.type == .keyDown {
            if !event.isARepeat { apply(machine.keyDown(at: event.timestamp)) }
        } else {
            apply(machine.keyUp(at: event.timestamp))
        }
        return true
    }

    /// Edit › Dictate (a click, no hold).
    func toggle() { apply(machine.toggle()) }

    func dismissFailure() { _ = machine.escape() }

    private func apply(_ effect: DictationMachine.Effect) {
        switch effect {
        case .none: break
        case .start: Task { await begin() }
        case .stop: Task { await end() }
        case .cancel:
            liveText = ""
            downloadingModel = false
            let engine = engine
            self.engine = nil
            Task { await engine?.cancel() }
        }
    }

    private func begin() async {
        target = Self.focusedTarget()
        lastInserted = ""
        liveText = ""
        ready = false
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "AletheDictationDenied") { return machine.failed(.microphoneDenied) }
        #endif
        guard await Self.microphoneAllowed() else {
            if machine.isActive { machine.failed(.microphoneDenied) }
            return
        }
        guard machine.isActive else { return }
        let engine = DictationEngine()
        self.engine = engine
        do {
            try await engine.start(locale: environment?.dictationLocale ?? .current,
                                   onModelDownload: { [weak self] in self?.downloadingModel = true },
                                   onResult: { [weak self] text, isFinal in self?.receive(text, isFinal: isFinal) })
            downloadingModel = false
            guard self.engine === engine else { return await engine.cancel() }
            ready = true
            switch machine.phase {
            case .starting: machine.started()
            case .finishing: await end()
            default: break
            }
        } catch {
            downloadingModel = false
            guard self.engine === engine else { return }
            self.engine = nil
            await engine.cancel()
            if machine.isActive {
                machine.failed(error as? DictationEngine.StartError == .languageUnsupported ? .languageUnsupported : .unavailable)
            }
        }
    }

    /// Stops listening; while the engine is still starting, `begin` calls this once it is up.
    private func end() async {
        guard let engine else {
            if machine.phase == .finishing, !downloadingModel { machine.finished() }
            return
        }
        guard ready else { return }
        self.engine = nil
        ready = false
        await engine.stop()
        liveText = ""
        machine.finished()
        target = nil
    }

    private func receive(_ text: String, isFinal: Bool) {
        guard machine.isActive else { return }
        if isFinal {
            liveText = ""
            insert(text)
        } else {
            liveText = text
        }
    }

    private func insert(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let last = lastInserted.last, !last.isWhitespace { text = " " + text }
        lastInserted = text
        switch target {
        case .terminal(let view)?: view.type(text)
        case .text(let client)?: client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        case nil: break
        }
    }

    private static func focusedTarget() -> Target? {
        let responder = NSApp.keyWindow?.firstResponder
        var view = responder as? NSView
        while let current = view {
            if let terminal = current as? TerminalPaneView { return .terminal(terminal) }
            view = current.superview
        }
        return (responder as? NSTextInputClient).map { .text($0) }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
