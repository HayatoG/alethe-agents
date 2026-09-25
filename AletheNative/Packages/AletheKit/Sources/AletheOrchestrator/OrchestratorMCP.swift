import Foundation
import AletheIntegrations

/// Runs the `alethe_*` tools. The core implements it; the transport only frames requests and answers.
public protocol OrchestratorToolHandler: Sendable {
    /// The tool's result object. A thrown error becomes an `isError` result for the planner.
    func callTool(name: String, arguments: OrderedJSONObject, planner: String?) async throws -> OrderedJSON
}

/// A tool refusal worded for the planner (upstream's `Err(String)`).
public struct OrchestratorToolError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The MCP surface over any byte transport (the app's loopback `/mcp` and the stdio helper):
/// upstream `handle_mcp_body` and `tools()`.
public enum OrchestratorMCP {
    public static let serverName = "alethe"
    /// Echoed when the client does not name a protocol version.
    public static let defaultProtocolVersion = "2025-06-18"

    /// The nine tool schemas, verbatim from upstream (`Resources/orchestrator-tools.json`).
    public static let tools: OrderedJSON = {
        guard let url = Bundle.module.url(forResource: "orchestrator-tools", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tools = try? OrderedJSON.parse(data)
        else {
            assertionFailure("orchestrator-tools.json is missing or unreadable")
            return .array([])
        }
        return tools
    }()

    /// Answers one JSON-RPC message. Returns nil when there is nothing to send back: a
    /// notification (no id) or a body that is not JSON.
    public static func handle(
        body: String,
        planner: String?,
        handler: some OrchestratorToolHandler
    ) async -> String? {
        guard let message = (try? OrderedJSON.parse(body))?.objectValue, let id = message["id"] else { return nil }
        let method = message["method"]?.stringValue ?? ""
        let params = message["params"]?.objectValue ?? [:]

        let response: OrderedJSON
        switch method {
        case "initialize":
            response = result(id: id, [
                "protocolVersion": .string(params["protocolVersion"]?.stringValue ?? defaultProtocolVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(serverName), "title": "Alethe", "version": "1"],
            ])
        case "tools/list":
            response = result(id: id, ["tools": tools])
        case "tools/call":
            let name = params["name"]?.stringValue ?? ""
            let arguments = params["arguments"]?.objectValue ?? [:]
            do {
                let value = try await handler.callTool(name: name, arguments: arguments, planner: planner)
                response = result(id: id, ["content": [["type": "text", "text": .string(value.compactRendered())]]])
            } catch {
                let reason = (error as? OrchestratorToolError)?.message ?? String(describing: error)
                response = result(id: id, [
                    "content": [["type": "text", "text": .string("error: \(reason)")]],
                    "isError": true,
                ])
            }
        case "ping":
            response = result(id: id, [:])
        default:
            response = [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": .string("unknown method \(method)")],
            ]
        }
        return response.compactRendered()
    }

    public static func handle(
        body: Data,
        planner: String?,
        handler: some OrchestratorToolHandler
    ) async -> String? {
        await handle(body: String(decoding: body, as: UTF8.self), planner: planner, handler: handler)
    }

    private static func result(id: OrderedJSON, _ result: OrderedJSONObject) -> OrderedJSON {
        ["jsonrpc": "2.0", "id": id, "result": .object(result)]
    }
}
