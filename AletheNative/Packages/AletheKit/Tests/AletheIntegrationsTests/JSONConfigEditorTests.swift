import Foundation
import Testing
@testable import AletheIntegrations

private let claudeConfig = """
{
  "numStartups": 42,
  "theme": "dark",
  "ratio": 1.50,
  "big": 12345678901234567890,
  "projects": {
    "/Users/me/app": {
      "allowedTools": [],
      "mcpServers": {
        "keep": { "command": "keep-me", "custom": true }
      }
    }
  },
  "mcpServers": {
    "zeta": { "type": "stdio", "command": "z", "userNote": "hand-added" },
    "alpha": { "type": "http", "url": "https://a.example/mcp" }
  },
  "tipsHistory": { "x": 1 }
}
"""

@Suite struct JSONConfigEditorTests {
    @Test func renderingAnUntouchedDocumentKeepsKeysOrderAndNumbers() throws {
        let editor = try JSONConfigEditor(parsing: claudeConfig)
        #expect(editor.root.keys == ["numStartups", "theme", "ratio", "big", "projects", "mcpServers", "tipsHistory"])
        let output = editor.rendered()
        #expect(output.contains("\"ratio\": 1.50"))
        #expect(output.contains("\"big\": 12345678901234567890"))
        #expect(output.hasSuffix("}\n"))
        #expect(try JSONConfigEditor(parsing: output) == editor)
    }

    @Test func upsertRewritesOnlyManagedKeysAndKeepsUnknownOnes() throws {
        var editor = try JSONConfigEditor(parsing: claudeConfig)
        try editor.upsertObject(
            at: ["mcpServers", "zeta"],
            managedKeys: ["type", "command", "args", "url", "env", "disabled"],
            values: [("type", .string("stdio")), ("command", .string("npx")), ("args", .array([.string("-y"), .string("zeta")]))]
        )
        let zeta = try #require(editor.value(at: ["mcpServers", "zeta"])?.objectValue)
        #expect(zeta.keys == ["userNote", "type", "command", "args"])
        #expect(zeta["userNote"] == .string("hand-added"))
        // Siblings and the rest of the file are untouched and in place.
        #expect(editor.value(at: ["mcpServers"])?.objectValue?.keys == ["zeta", "alpha"])
        #expect(editor.root.keys.last == "tipsHistory")
        #expect(editor.value(at: ["numStartups"]) == .number("42"))
    }

    @Test func setCreatesIntermediateObjectsAndAppendsNewKeys() throws {
        var editor = try JSONConfigEditor(parsing: claudeConfig)
        try editor.set(.object(OrderedJSONObject([("command", .string("new"))])), at: ["projects", "/Users/me/other", "mcpServers", "new"])
        #expect(editor.value(at: ["projects"])?.objectValue?.keys == ["/Users/me/app", "/Users/me/other"])
        #expect(editor.value(at: ["projects", "/Users/me/other", "mcpServers", "new", "command"]) == .string("new"))
        #expect(editor.value(at: ["projects", "/Users/me/app", "mcpServers", "keep", "custom"]) == .bool(true))
    }

    @Test func settingAnExistingKeyKeepsItsPosition() throws {
        var editor = try JSONConfigEditor(parsing: claudeConfig)
        try editor.set(.string("light"), at: ["theme"])
        #expect(editor.root.keys == ["numStartups", "theme", "ratio", "big", "projects", "mcpServers", "tipsHistory"])
        #expect(editor.value(at: ["theme"]) == .string("light"))
    }

    @Test func removeShiftsWithoutReordering() throws {
        var editor = try JSONConfigEditor(parsing: claudeConfig)
        try editor.set(.string("s"), at: ["mcpServers", "beta"])
        let removed = try editor.remove(at: ["mcpServers", "zeta"])
        #expect(removed?.objectValue?["command"] == .string("z"))
        #expect(editor.value(at: ["mcpServers"])?.objectValue?.keys == ["alpha", "beta"])
        #expect(try editor.remove(at: ["mcpServers", "missing"]) == nil)
        #expect(try editor.remove(at: ["nowhere", "deep"]) == nil)
        #expect(editor.value(at: ["nowhere"]) == nil)
    }

    @Test func neverReplacesANonObjectOnThePath() throws {
        var editor = try JSONConfigEditor(parsing: claudeConfig)
        #expect(throws: JSONConfigError.notAnObject(path: ["theme"])) {
            try editor.set(.bool(true), at: ["theme", "x"])
        }
        #expect(throws: JSONConfigError.notAnObject(path: ["numStartups"])) {
            try editor.upsertObject(at: ["numStartups"], managedKeys: [], values: [])
        }
        #expect(throws: JSONConfigError.emptyPath) { try editor.set(.null, at: []) }
        #expect(editor.value(at: ["theme"]) == .string("dark"))
    }

    @Test func emptyFileIsAnEmptyObject() throws {
        var editor = try JSONConfigEditor(parsing: "  \n")
        #expect(editor.root.isEmpty)
        #expect(editor.rendered() == "{}\n")
        try editor.set(.bool(false), at: ["mcp", "x", "enabled"])
        #expect(editor.rendered() == """
        {
          "mcp": {
            "x": {
              "enabled": false
            }
          }
        }

        """)
    }

    @Test func rejectsInvalidJSONWithItsLineAndANonObjectRoot() {
        do {
            _ = try JSONConfigEditor(parsing: "{\n  \"a\": 1,\n  \"b\": ]\n}")
            Issue.record("expected an error")
        } catch {
            guard case .unparsable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.line == 3)
            #expect(detail.column == 8)
        }
        #expect(throws: JSONConfigError.rootNotAnObject) { try JSONConfigEditor(parsing: "[1, 2]") }
        // Trailing commas and comments are not JSON without `allowComments`.
        #expect(throws: (any Error).self) { try JSONConfigEditor(parsing: "{\"a\": 1,}") }
    }

    @Test func readsJSONCWhenAllowed() throws {
        let source = """
        // OpenCode config
        {
          "$schema": "https://opencode.ai/config.json", // schema
          "mcp": { "x": { "type": "local", "command": ["x"], }, },
        }
        """
        let editor = try JSONConfigEditor(parsing: source, allowComments: true)
        #expect(editor.root.keys == ["$schema", "mcp"])
        #expect(editor.value(at: ["mcp", "x", "command"]) == .array([.string("x")]))
    }
}

@Suite struct OrderedJSONTests {
    @Test func parsesEscapesAndRendersThemLikeSerde() throws {
        let value = try OrderedJSON.parse(#"{"s": "a\"b\\c\/d\n\t\u00e9\ud83d\ude00\u0001", "e": [], "o": {}}"#)
        #expect(value.objectValue?["s"] == .string("a\"b\\c/d\n\té😀\u{01}"))
        #expect(value.rendered() == """
        {
          "s": "a\\"b\\\\c/d\\n\\té😀\\u0001",
          "e": [],
          "o": {}
        }
        """)
    }

    @Test func duplicateKeysKeepTheLastValueAtTheFirstPosition() throws {
        let value = try OrderedJSON.parse(#"{"a": 1, "b": 2, "a": 3}"#)
        #expect(value.objectValue?.keys == ["a", "b"])
        #expect(value.objectValue?["a"]?.intValue == 3)
    }

    @Test func rejectsMalformedInput() {
        for bad in ["", "{", "[1,]", "01", "1.", "-", "\"\\x\"", "\"\n\"", "tru", "{} x", "\"\\ud800\""] {
            #expect(throws: OrderedJSONParseError.self, "\(bad)") { try OrderedJSON.parse(bad) }
        }
    }

    @Test func bridgesCodable() throws {
        struct Entry: Codable, Equatable { var command: String; var args: [String] }
        let value = try OrderedJSON(encoding: Entry(command: "npx", args: ["-y", "pkg"]))
        #expect(value.objectValue?.keys == ["args", "command"])
        #expect(try value.decode(Entry.self) == Entry(command: "npx", args: ["-y", "pkg"]))
        #expect(OrderedJSON.integer(7).intValue == 7)
        #expect(OrderedJSON.number("1e2").intValue == 100)
    }
}
