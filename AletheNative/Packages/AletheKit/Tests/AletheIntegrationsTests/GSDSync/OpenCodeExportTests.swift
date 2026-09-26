import Foundation
import Testing
@testable import AletheIntegrations

@Suite(.timeLimit(.minutes(1))) struct OpenCodeExportTests {
    static let sample = #"""
    Exporting session: ses_child1
    {
      "info": {
        "id": "ses_child1",
        "title": "GSD sync",
        "model": { "id": "mimo-v2.5-free", "providerID": "opencode" },
        "tokens": { "input": 1200, "output": 300, "reasoning": 10, "cache": { "read": 0, "write": 0 } },
        "time": { "created": 1700000000000, "updated": 1700000060000 }
      },
      "messages": [
        {
          "info": { "id": "msg_1", "sessionID": "ses_child1", "role": "user", "time": { "created": 1700000000000 } },
          "parts": [ { "id": "p1", "sessionID": "ses_child1", "messageID": "msg_1", "type": "text", "text": "Sync the planning folder" } ]
        },
        {
          "info": {
            "id": "msg_2", "sessionID": "ses_child1", "role": "assistant",
            "time": { "created": 1700000001000, "completed": 1700000059000 },
            "model": { "providerID": "opencode", "modelID": "mimo-v2.5-free" }
          },
          "parts": [
            { "type": "step-start" },
            { "id": "p2", "sessionID": "ses_child1", "messageID": "msg_2", "type": "reasoning", "text": "Reading plan.md" },
            { "id": "p3", "sessionID": "ses_child1", "messageID": "msg_2", "type": "tool", "tool": "write", "callID": "c1",
              "state": { "status": "completed", "input": { "description": "Write goal.md", "filePath": "/x" }, "output": "ok" } },
            { "id": "p4", "sessionID": "ses_child1", "messageID": "msg_2", "type": "tool", "tool": "gsd_record_step", "callID": "c2",
              "state": { "status": "running", "input": { "category": "ui", "description": 3 } } },
            { "id": "p5", "sessionID": "ses_child1", "messageID": "msg_2", "type": "patch", "hash": "abc" },
            { "id": "p6", "sessionID": "ses_child1", "messageID": "msg_2", "type": "text", "text": "Done." },
            { "type": "step-finish", "reason": "stop" },
            { "type": "future-kind" }
          ]
        },
        { "info": { "id": "msg_3", "role": "system" }, "parts": [] }
      ]
    }
    """#

    @Test func parsesTheSessionAfterTheStatusLine() throws {
        let session = try OpenCodeExport.parse(Self.sample)
        #expect(session.id == "ses_child1")
        #expect(session.title == "GSD sync")
        #expect(session.modelID == "mimo-v2.5-free")
        #expect(session.totalTokens == 1500)
        #expect(session.updatedAt == Date(timeIntervalSince1970: 1_700_000_060))
        // The message with an unknown role is dropped.
        #expect(session.messages.map(\.id) == ["msg_1", "msg_2"])
        #expect(session.messages[0].role == .user)
        #expect(session.messages[0].parts == [.text("Sync the planning folder")])
        #expect(session.messages[1].modelID == "mimo-v2.5-free")
        #expect(session.messages[1].completedAt == Date(timeIntervalSince1970: 1_700_000_059))
    }

    @Test func parsesEveryPartKind() throws {
        let parts = try OpenCodeExport.parse(Self.sample).messages[1].parts
        #expect(parts == [
            .other(type: "step-start"),
            .reasoning("Reading plan.md"),
            .tool(name: "write", status: "completed", input: "Write goal.md", output: "ok"),
            .tool(name: "gsd_record_step", status: "running", input: "{\n  \"category\" : \"ui\",\n  \"description\" : 3\n}", output: nil),
            .patch,
            .text("Done."),
            .other(type: "step-finish"),
            .other(type: "future-kind"),
        ])
    }

    @Test func outputWithoutJSONIsAnError() {
        #expect(throws: OpenCodeExportError.notJSON) { try OpenCodeExport.parse("Session not found") }
        #expect(throws: OpenCodeExportError.notJSON) { try OpenCodeExport.parse("Exporting { broken") }
    }

    @Test func aSessionWithoutTokensHasNoTotal() throws {
        let session = try OpenCodeExport.parse(#"{"info": {"id": "s"}, "messages": []}"#)
        #expect(session.totalTokens == nil)
        #expect(session.messages.isEmpty)
    }

    @Test func onlyPlainSessionIDsArePassedToTheCLI() {
        #expect(OpenCodeExport.isValidSessionID("ses_abc-123"))
        #expect(!OpenCodeExport.isValidSessionID(""))
        #expect(!OpenCodeExport.isValidSessionID("--help"))
        #expect(!OpenCodeExport.isValidSessionID("ses abc"))
        #expect(!OpenCodeExport.isValidSessionID("ses/../x"))
        #expect(!OpenCodeExport.isValidSessionID("séssion"))
        #expect(!OpenCodeExport.isValidSessionID(String(repeating: "a", count: 129)))
    }

    @Test func anInvalidSessionIDNeverStartsTheCLI() async {
        await #expect(throws: OpenCodeExportError.invalidSessionID) {
            try await OpenCodeExport.run(sessionID: "-x", directory: FileManager.default.temporaryDirectory,
                                         executable: URL(filePath: "/nonexistent/opencode"))
        }
    }
}
