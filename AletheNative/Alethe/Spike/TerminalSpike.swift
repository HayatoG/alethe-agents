import AletheTerminal
import AppKit
import Foundation

/// P0-6 measurement hooks, driven by launch arguments (debug builds only):
///   -AletheSpikeCommand "<cmd>"   run <cmd> through the login shell instead of an interactive shell
///   -AletheSpikeDump <path>       write the viewport text to <path> twice a second
///   -AletheSpikeScript <path>     run the scripted input below, then quit
///
/// Input is injected with `NSWindow.sendEvent` into this app's own window — the same path real key
/// events take (key equivalents, then the first responder) — so nothing reaches other apps.
///
/// Script lines:
///   wait <ms>                    type <text>                 key <name> [cmd|shift|ctrl|opt]...
///   ime-mark <text>              ime-commit <text>           search <text> | search-next | search-end
///   dump <path>                  latency <count> <path>      dead <key> [shift]      quit
enum TerminalSpike {
    static func launch() -> PTYLaunch {
        #if DEBUG
        let command = UserDefaults.standard.string(forKey: "AletheSpikeCommand")
        return ShellLaunch.loginShell(command: command)
        #else
        return ShellLaunch.loginShell()
        #endif
    }

    @MainActor
    static func attach(_ pane: TerminalPaneView) {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "AletheSpikeDump") {
            Task { @MainActor [weak pane] in
                while let pane {
                    if let text = pane.viewportText() {
                        try? text.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        if let path = defaults.string(forKey: "AletheSpikeScript"),
           let script = try? String(contentsOfFile: path, encoding: .utf8) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await SpikeScript(pane: pane).run(script)
            }
        }
        #endif
    }
}

#if DEBUG
@MainActor
private struct SpikeScript {
    let pane: TerminalPaneView

    func run(_ script: String) async {
        for line in script.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = parts.first, !command.hasPrefix("#") else { continue }
            let argument = parts.count > 1 ? parts[1] : ""
            switch command {
            case "wait":
                try? await Task.sleep(for: .milliseconds(Int(argument) ?? 0))
            case "type":
                for character in argument { sendCharacter(character) }
            case "key":
                let words = argument.split(separator: " ").map(String.init)
                if let name = words.first { sendKey(name, modifiers: Set(words.dropFirst())) }
            case "dead":
                // A dead key as the hardware sends it: key code only, no characters of its own.
                let words = argument.split(separator: " ").map(String.init)
                if let name = words.first, let character = name.first, let code = Self.keyCodes[character] {
                    post(code: code, characters: "", ignoring: String(character),
                         flags: words.contains("shift") ? .shift : [])
                }
            case "ime-mark":
                pane.terminalView.setMarkedText(argument, selectedRange: NSRange(location: argument.utf16.count, length: 0),
                                                replacementRange: NSRange(location: NSNotFound, length: 0))
            case "ime-commit":
                pane.terminalView.insertText(argument, replacementRange: NSRange(location: NSNotFound, length: 0))
            case "search":
                pane.updateSearch(argument)
            case "search-next":
                pane.searchNext()
            case "search-end":
                pane.closeSearch()
            case "dump":
                try? (pane.viewportText() ?? "").write(toFile: argument, atomically: true, encoding: .utf8)
            case "latency":
                let words = argument.split(separator: " ").map(String.init)
                await measureLatency(count: Int(words[0]) ?? 50, path: words[1])
            case "quit":
                NSApp.terminate(nil)
            default:
                continue
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    // MARK: - Events

    /// US-layout virtual key codes for the characters scripts type.
    private static let keyCodes: [Character: UInt16] = {
        var map: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
            "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
            "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
            ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
            ">": ".", "?": "/", "~": "`",
        ]
        for (symbol, base) in shifted { map[symbol] = map[base] }
        return map
    }()

    private static let namedKeys: [String: (code: UInt16, text: String)] = [
        "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "delete": (51, "\u{7f}"),
        "escape": (53, "\u{1b}"), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
        "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
    ]

    private func sendCharacter(_ character: Character) {
        let lower = Character(character.lowercased())
        let code = Self.keyCodes[lower] ?? Self.keyCodes[character] ?? 0
        let needsShift = character.isUppercase || (Self.keyCodes[character] != nil && !"abcdefghijklmnopqrstuvwxyz0123456789=-][';\\,/.` ".contains(character))
        post(code: code, characters: String(character), ignoring: String(lower), flags: needsShift ? .shift : [])
    }

    private func sendKey(_ name: String, modifiers: Set<String>) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("cmd") { flags.insert(.command) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("ctrl") { flags.insert(.control) }
        if modifiers.contains("opt") { flags.insert(.option) }
        if let named = Self.namedKeys[name] {
            let text = name == "tab" && flags.contains(.shift) ? "\u{19}" : named.text
            post(code: named.code, characters: text, ignoring: named.text, flags: flags)
        } else if let character = name.first, let code = Self.keyCodes[character] {
            var text = String(character)
            if flags.contains(.control), let ascii = character.asciiValue { text = String(UnicodeScalar(ascii & 0x1f)) }
            post(code: code, characters: text, ignoring: String(character), flags: flags)
        }
    }

    private func post(code: UInt16, characters: String, ignoring: String, flags: NSEvent.ModifierFlags) {
        guard let window = pane.window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: ignoring,
                isARepeat: false, keyCode: code
            ) else { continue }
            window.sendEvent(event)
        }
    }

    // MARK: - Latency

    /// Key event → bytes written to the PTY (the app's own input latency), and key event → echo
    /// read back from the PTY (adds the shell's round trip).
    private func measureLatency(count: Int, path: String) async {
        let probe = LatencyProbe()
        let inputID = pane.tap.observeInput { _ in probe.markInput() }
        let outputID = pane.tap.observeOutput { _ in probe.markOutput() }
        var toInput: [Double] = []
        var toEcho: [Double] = []
        for _ in 0..<count {
            probe.reset()
            let start = ProcessInfo.processInfo.systemUptime
            sendCharacter("x")
            try? await Task.sleep(for: .milliseconds(40))
            if let input = probe.input { toInput.append((input - start) * 1000) }
            if let output = probe.output { toEcho.append((output - start) * 1000) }
            sendKey("delete", modifiers: [])
            try? await Task.sleep(for: .milliseconds(40))
        }
        pane.tap.remove(inputID)
        pane.tap.remove(outputID)
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "n=0" }
            let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            return String(format: "n=%d median=%.2fms p95=%.2fms max=%.2fms", sorted.count, p(0.5), p(0.95), sorted.last!)
        }
        let report = "key->pty-write: \(stats(toInput))\nkey->echo: \(stats(toEcho))\n"
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

private final class LatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inputTime: Double?
    private var outputTime: Double?

    func reset() { lock.withLock { inputTime = nil; outputTime = nil } }
    func markInput() { lock.withLock { if inputTime == nil { inputTime = ProcessInfo.processInfo.systemUptime } } }
    func markOutput() { lock.withLock { if outputTime == nil { outputTime = ProcessInfo.processInfo.systemUptime } } }
    var input: Double? { lock.withLock { inputTime } }
    var output: Double? { lock.withLock { outputTime } }
}
#endif
