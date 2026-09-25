import Foundation
import Testing
@testable import AletheFoundation

/// Golden cases ported from upstream `mcp_agents.rs` (Codex adapter, `toml_edit`) and
/// `graphify.rs` (`graphify_codex_config_write`), plus `toml_edit`-style round trips.
@Suite struct TOMLDocumentTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "toml",
                                                 subdirectory: "Fixtures/TOML"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func codex() throws -> TOMLDocument {
        try TOMLDocument(parsing: fixture("codex-config"))
    }

    private let probe: TOMLTable = ["command": "node", "args": ["-e", "0"]]

    private func server(_ name: String) -> [String] { ["mcp_servers", name] }

    /// The line of a parse failure, or `nil` when the source parses.
    private func malformedLine(_ raw: String) -> Int? {
        do {
            _ = try TOMLDocument(parsing: raw)
            return nil
        } catch TOMLError.malformed(let line, _, _) {
            return line
        } catch {
            return nil
        }
    }

    // MARK: Reading (upstream parse_codex cases)

    @Test func readsEveryCodexTableShape() throws {
        let document = try codex()
        let servers = try #require(document.table(at: ["mcp_servers"]))
        #expect(servers.keys == ["discord", "figma", "swarm"])

        let discord = try #require(document.table(at: server("discord")))
        #expect(discord["command"] == "npx")
        #expect(discord["args"]?.stringArrayValue == ["-y", "@quadslab.io/discord-mcp"])
        #expect(document.value(at: server("discord") + ["env", "DISCORD_TOKEN"]) == "a-live-secret-token-value")
        #expect(discord["env"]?.tableValue?.style == .section)

        #expect(document.value(at: server("figma") + ["url"])?.stringValue == "https://mcp.figma.com/mcp")
        #expect(document.table(at: ["projects", #"D:\repo\one"#])?["trust_level"] == "trusted")
    }

    @Test func readsInlineEnvAndPassthroughList() throws {
        let swarm = try #require(try codex().table(at: server("swarm")))
        let env = try #require(swarm["env"]?.tableValue)
        #expect(env.style == .inline)
        #expect(env["NODE_ENV"] == "production")
        #expect(env["QUADRANT"] == "1")
        #expect(swarm["env_vars"]?.stringArrayValue == ["QUADRANT", "SESSION"])
        #expect(swarm["args"]?.stringArrayValue == [#"C:\path\server.js"#])
    }

    @Test func readsIntegerAndFloatTimeouts() throws {
        let swarm = try #require(try codex().table(at: server("swarm")))
        #expect(swarm["startup_timeout_sec"] == .integer(30))
        #expect(swarm["tool_timeout_sec"] == .float(120))
        #expect(swarm["tool_timeout_sec"]?.doubleValue == 120)
    }

    @Test func readsArraysOfTables() throws {
        let hooks = try #require(try codex().value(at: ["hooks", "PreToolUse"])?.arrayValue)
        #expect(hooks.count == 1)
        #expect(hooks.first?.tableValue?["name"] == "gate")
    }

    @Test func fileWithoutServersOrEmptyIsNotAnError() throws {
        #expect(try TOMLDocument(parsing: "model = \"x\"\n").table(at: ["mcp_servers"]) == nil)
        let empty = try TOMLDocument(parsing: "")
        #expect(empty.root.isEmpty)
        #expect(empty.text == "")
    }

    @Test func readsEveryValueKind() throws {
        let raw = #"""
        str = "tab\there \u00E9"
        lit = 'C:\path'
        ml = """
        line one \
          continued"""
        mll = '''
        raw \n'''
        hex = 0xff
        oct = 0o17
        bin = 0b101
        big = 1_000
        neg = -3
        flt = 6.02e23
        inf = -inf
        stamp = 1979-05-27T07:32:00Z
        spaced = 1979-05-27 07:32:00
        day = 1979-05-27
        time = 07:32:00
        nested = { a.b = 1 }
        arr = [1, [2, 3], { x = "y" }, ]
        "quoted key" = true
        dotted.inner = false

        """#
        let document = try TOMLDocument(parsing: raw)
        #expect(document.value(at: ["str"]) == "tab\there é")
        #expect(document.value(at: ["lit"]) == #"C:\path"#)
        #expect(document.value(at: ["ml"]) == "line one continued")
        #expect(document.value(at: ["mll"]) == #"raw \n"#)
        #expect(document.value(at: ["hex"]) == 255)
        #expect(document.value(at: ["oct"]) == 15)
        #expect(document.value(at: ["bin"]) == 5)
        #expect(document.value(at: ["big"]) == 1000)
        #expect(document.value(at: ["neg"]) == -3)
        #expect(document.value(at: ["flt"]) == 6.02e23)
        #expect(document.value(at: ["inf"]) == .float(-.infinity))
        #expect(document.value(at: ["stamp"]) == .datetime("1979-05-27T07:32:00Z"))
        #expect(document.value(at: ["spaced"]) == .datetime("1979-05-27 07:32:00"))
        #expect(document.value(at: ["day"]) == .datetime("1979-05-27"))
        #expect(document.value(at: ["time"]) == .datetime("07:32:00"))
        #expect(document.value(at: ["nested", "a", "b"]) == 1)
        #expect(document.value(at: ["arr"]) == .array([1, [2, 3], .table(["x": "y"])]))
        #expect(document.value(at: ["quoted key"]) == true)
        #expect(document.value(at: ["dotted", "inner"]) == false)
        #expect(document.text == raw)
    }

    // MARK: Editing (upstream codex_upsert / codex_remove / codex_set_enabled cases)

    @Test func upsertAddsATableAfterItsSiblingsAndLeavesTheRestUntouched() throws {
        var document = try codex()
        try document.upsertTable(probe, at: server("alethe-probe"))
        #expect(document.text == (try fixture("codex-upsert-probe")))

        let original = try fixture("codex-config")
        let inserted = "\n[mcp_servers.alethe-probe]\ncommand = \"node\"\nargs = [\"-e\", \"0\"]\n"
        #expect(document.text.replacingOccurrences(of: inserted, with: "") == original)
        #expect(document.table(at: ["mcp_servers"])?.count == 4)
    }

    @Test func removeTakesTheEnvSubtableAndItsSecretWithIt() throws {
        var document = try codex()
        try document.removeTable(at: server("discord"))
        #expect(document.text == (try fixture("codex-remove-discord")))
        #expect(!document.text.contains("a-live-secret-token-value"))
        #expect(document.table(at: server("figma")) != nil)
        #expect(document.value(at: ["hooks", "PreToolUse"]) != nil)
    }

    @Test func setEnabledFlipsOnlyThatServer() throws {
        var document = try codex()
        try document.setValue(false, forKey: "enabled", inTableAt: server("figma"))
        #expect(document.text == (try fixture("codex-disable-figma")))
        #expect(document.value(at: server("figma") + ["enabled"]) == false)
        #expect(document.value(at: server("discord") + ["enabled"]) == nil)
    }

    @Test func upsertKeepsAHandWrittenEnvSectionAsASection() throws {
        var document = try codex()
        let discord: TOMLTable = [
            "command": "npx",
            "args": ["-y", "@quadslab.io/discord-mcp"],
            "env": .table(TOMLTable([("DISCORD_GUILD_ID", "456")], style: .inline)),
        ]
        try document.upsertTable(discord, at: server("discord"))
        #expect(document.text == (try fixture("codex-upsert-discord-env")))
        #expect(document.text.contains("[mcp_servers.discord.env]"))
        #expect(!document.text.contains("a-live-secret-token-value"))
    }

    @Test func upsertKeepsAnInlineEnvInline() throws {
        var document = try codex()
        var swarm = try #require(document.table(at: server("swarm")))
        swarm["env"] = .table(["NODE_ENV": "staging"])
        try document.upsertTable(swarm, at: server("swarm"))
        #expect(document.text == (try fixture("codex-upsert-swarm-env")))
    }

    @Test func upsertRoundTripsTimeoutsAndPassthrough() throws {
        var document = try codex()
        var server = probe
        server["startup_timeout_sec"] = 12
        server["tool_timeout_sec"] = 90
        server["env"] = .table(TOMLTable([("MODE", "prod")], style: .inline))
        server["env_vars"] = ["FOO"]
        try document.upsertTable(server, at: self.server("alethe-probe"))

        let reread = try TOMLDocument(parsing: document.text)
        #expect(reread.table(at: self.server("alethe-probe")) == server)
        #expect(document.text.contains("env = { MODE = \"prod\" }"))
    }

    @Test func mutationsReportNotFoundAndChangeNothing() throws {
        var document = try codex()
        let before = document
        #expect(throws: TOMLError.notFound) { try document.removeTable(at: self.server("ghost")) }
        #expect(throws: TOMLError.notFound) {
            try document.setValue(false, forKey: "enabled", inTableAt: self.server("ghost"))
        }
        #expect(throws: TOMLError.notFound) {
            try document.removeValue(forKey: "enabled", inTableAt: self.server("figma"))
        }
        #expect(document == before)
    }

    @Test func upsertKeepsAnExplicitServersHeaderAndItsComment() throws {
        var document = try TOMLDocument(parsing: "# my servers\n[mcp_servers]\n\n[mcp_servers.figma]\nurl = \"https://x\"\n")
        try document.upsertTable(probe, at: server("alethe-probe"))
        #expect(document.text == """
        # my servers
        [mcp_servers]

        [mcp_servers.figma]
        url = "https://x"

        [mcp_servers.alethe-probe]
        command = "node"
        args = ["-e", "0"]

        """)
        #expect(document.table(at: ["mcp_servers"])?.count == 2)
    }

    // MARK: graphify_codex_config_write

    @Test func graphifyWriteCreatesAndReplacesOnlyItsOwnTable() throws {
        let original = "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"other-cmd\"\n"
        let graphify: TOMLTable = ["command": "graphify", "args": [#"/Users/me/repo"#, "--mcp"]]
        var document = try TOMLDocument(parsing: original)
        try document.upsertTable(graphify, at: server("graphify"))
        let once = document.text
        #expect(once == original + "\n[mcp_servers.graphify]\ncommand = \"graphify\"\nargs = [\"/Users/me/repo\", \"--mcp\"]\n")

        try document.upsertTable(graphify, at: server("graphify"))
        #expect(document.text == once)
        #expect(document.text.components(separatedBy: "[mcp_servers.graphify]").count == 2)
        #expect(document.text.components(separatedBy: "[mcp_servers.other]").count == 2)
    }

    // MARK: Round trips (toml_edit-style)

    @Test func tableAddedThenRemovedRestoresTheFile() throws {
        let original = try fixture("codex-config")
        var document = try TOMLDocument(parsing: original)
        try document.upsertTable(probe, at: server("alethe-probe"))
        try document.removeTable(at: server("alethe-probe"))
        #expect(document.text == original)
    }

    @Test func keyAddedThenRemovedRestoresTheFile() throws {
        let original = try fixture("codex-config")
        var document = try TOMLDocument(parsing: original)
        try document.setValue(false, forKey: "enabled", inTableAt: server("figma"))
        try document.removeValue(forKey: "enabled", inTableAt: server("figma"))
        #expect(document.text == original)
    }

    @Test func valueChangedAndChangedBackKeepsCommentsAndSpacing() throws {
        let original = try fixture("commented")
        var document = try TOMLDocument(parsing: original)

        try document.setValue(true, forKey: "enabled", inTableAt: server("beta"))
        #expect(document.text == original.replacingOccurrences(of: "enabled = false", with: "enabled = true"))
        try document.setValue(false, forKey: "enabled", inTableAt: server("beta"))
        #expect(document.text == original)

        var alpha = try #require(document.table(at: server("alpha")))
        alpha["command"] = "alpha2"
        try document.upsertTable(alpha, at: server("alpha"))
        #expect(document.text == original.replacingOccurrences(
            of: "command = \"alpha\"   # keep this spacing", with: "command = \"alpha2\"   # keep this spacing"))
        alpha["command"] = "alpha"
        try document.upsertTable(alpha, at: server("alpha"))
        #expect(document.text == original)
    }

    @Test func removingATableTakesItsCommentAndLeavesItsNeighboursByteIdentical() throws {
        let original = try fixture("commented")
        var document = try TOMLDocument(parsing: original)
        try document.removeTable(at: server("beta"))
        let cut = try #require(original.range(of: "\n# Beta is disabled"))
        #expect(document.text == String(original[..<cut.lowerBound]))
    }

    @Test func rootKeyEditsKeepEveryTable() throws {
        let original = try fixture("codex-config")
        var document = try TOMLDocument(parsing: original)
        try document.setValue("gpt-6", forKey: "model")
        #expect(document.text == original.replacingOccurrences(of: "gpt-5.6-sol", with: "gpt-6"))
        try document.setValue("gpt-5.6-sol", forKey: "model")
        #expect(document.text == original)
    }

    // MARK: Layouts

    @Test func editsInlineServerForms() throws {
        var document = try TOMLDocument(parsing: "[mcp_servers]\nfoo = { command = \"x\" } # hand-written\n")
        try document.upsertTable(["command": "y", "args": ["1"]], at: server("foo"))
        #expect(document.text == "[mcp_servers]\nfoo = { command = \"y\", args = [\"1\"] } # hand-written\n")
        try document.setValue(false, forKey: "enabled", inTableAt: server("foo"))
        #expect(document.value(at: server("foo") + ["enabled"]) == false)
        try document.removeTable(at: server("foo"))
        #expect(document.text == "[mcp_servers]\n")

        var nested = try TOMLDocument(parsing: "mcp_servers = { a = { command = \"x\" }, b = { command = \"y\" } }\n")
        try nested.removeTable(at: server("a"))
        #expect(nested.text == "mcp_servers = { b = { command = \"y\" } }\n")
    }

    @Test func addsAnInlineTableToAnExistingSection() throws {
        var document = try TOMLDocument(parsing: "[mcp_servers]\n")
        try document.upsertTable(TOMLTable([("command", "z")], style: .inline), at: server("n"))
        #expect(document.text == "[mcp_servers]\nn = { command = \"z\" }\n")
    }

    @Test func givesAnImplicitTableItsOwnHeader() throws {
        var document = try TOMLDocument(parsing: "[mcp_servers.x.env]\nA = \"1\"\n")
        try document.upsertTable(["command": "c", "env": .table(["A": "1"])], at: server("x"))
        #expect(document.text == "[mcp_servers.x]\ncommand = \"c\"\n\n[mcp_servers.x.env]\nA = \"1\"\n")
    }

    @Test func writesIntoEmptyAndUnterminatedFiles() throws {
        var empty = try TOMLDocument(parsing: "")
        try empty.upsertTable(["command": "c"], at: server("x"))
        #expect(empty.text == "[mcp_servers.x]\ncommand = \"c\"\n")

        var unterminated = try TOMLDocument(parsing: "model = \"x\"")
        try unterminated.upsertTable(["command": "c"], at: server("x"))
        #expect(unterminated.text == "model = \"x\"\n\n[mcp_servers.x]\ncommand = \"c\"\n")
    }

    @Test func keepsCRLFLineEndings() throws {
        var document = try TOMLDocument(parsing: "a = 1\r\n[t]\r\nk = \"v\"\r\n")
        try document.setValue(false, forKey: "enabled", inTableAt: ["t"])
        #expect(document.text == "a = 1\r\n[t]\r\nk = \"v\"\r\nenabled = false\r\n")
    }

    @Test func writesNewSubtablesAsSections() throws {
        var document = try TOMLDocument(parsing: "")
        try document.upsertTable(["command": "c", "env": .table(["K": "v"])], at: server("x"))
        #expect(document.text == "[mcp_servers.x]\ncommand = \"c\"\n\n[mcp_servers.x.env]\nK = \"v\"\n")
        try document.removeTable(at: server("x"))
        #expect(document.text == "")
    }

    @Test func rendersKeysAndValuesForOverrides() {
        #expect(TOMLRender.keyPath(["mcp_servers", "my server", "args"]) == #"mcp_servers."my server".args"#)
        #expect(TOMLValue.array(["-y", #"C:\x"#]).tomlText == #"["-y", "C:\\x"]"#)
        #expect(TOMLValue.string("a\"b\n").tomlText == #""a\"b\n""#)
        #expect(TOMLValue.float(2).tomlText == "2.0")
    }

    // MARK: Malformed input

    @Test func malformedInputReportsALineAndNoContent() throws {
        let raw = "[mcp_servers.broken\ntoken = \"secret-value\""
        do {
            _ = try TOMLDocument(parsing: raw)
            Issue.record("expected a parse error")
        } catch let error as TOMLError {
            guard case .malformed(let line, _, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(line == 1)
            #expect(!error.description.contains("secret-value"))
        }
    }

    @Test func malformedInputLines() {
        #expect(malformedLine("a = 1\nb = \n") == 2)
        #expect(malformedLine("a = 1\na = 2\n") == 2)
        #expect(malformedLine("[a]\nx = 1\n[a]\n") == 3)
        #expect(malformedLine("s = \"unterminated\n") == 1)
        #expect(malformedLine("a = 1\n\nb = 1 c = 2\n") == 3)
        #expect(malformedLine("t = { a = 1 }\n[t]\n") == 2)
        #expect(malformedLine("n = 012\n") == 1)
        #expect(malformedLine("a = [1,,2]\n") == 1)
        #expect(malformedLine("ok = true\n") == nil)
    }

    @Test func pathsThroughValuesOrTableArraysAreRefused() throws {
        var scalar = try TOMLDocument(parsing: "mcp_servers = \"x\"\n")
        #expect(throws: TOMLError.conflict) { try scalar.upsertTable(probe, at: self.server("a")) }

        var hooks = try TOMLDocument(parsing: "[[hooks.PreToolUse]]\nname = \"gate\"\n")
        let before = hooks
        #expect(throws: TOMLError.unsupportedLayout) {
            try hooks.upsertTable(["x": 1], at: ["hooks", "PreToolUse", "x"])
        }
        #expect(hooks == before)
    }
}
