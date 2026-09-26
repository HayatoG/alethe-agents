// Alethe's orchestrator as a stdio MCP server.
//
//   alethe-orchestrator-mcp --bridge <file>   a Codex planner's link to the running app: each line
//                                             goes to the app's loopback /mcp (endpoint, token and
//                                             planner read from the private per-launch file)
//   alethe-orchestrator-mcp                   standalone: its own core with Codex workers
//                                             (ALETHE_CODEX or PATH; ALETHE_MAX_WORKERS)
import AletheOrchestrator
import Foundation

signal(SIGPIPE, SIG_IGN)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("[alethe-orchestrator] \(message)\n".utf8))
    exit(code)
}

func runBridge(path: String) async {
    let file: OrchestratorBridgeFile
    do {
        file = try OrchestratorBridgeFile.read(from: URL(filePath: path))
    } catch {
        // Never the file's contents: they hold the token.
        fail("cannot use the bridge file (\(error)); reopen the terminal in Alethe", code: 66)
    }
    let bridge = OrchestratorBridge(file: file)
    await OrchestratorStdio.serve(input: .standardInput, output: .standardOutput) { await bridge.handle(line: $0) }
}

func runStandalone() async {
    let setup = OrchestratorStandalone.setup()
    if setup.codex == nil {
        FileHandle.standardError.write(Data("[alethe-orchestrator] codex not found on PATH; delegation will fail\n".utf8))
    }
    let core = OrchestratorCore(configuration: setup.configuration)
    // Workers run in their own process groups: end and reap them when the client stops the server.
    let sources = [SIGTERM, SIGINT, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            Task {
                await core.shutdown()
                exit(0)
            }
        }
        source.resume()
        return source
    }
    await OrchestratorStdio.serve(input: .standardInput, output: .standardOutput, handle: OrchestratorStdio.standalone(core))
    await core.shutdown()
    sources.forEach { $0.cancel() }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case OrchestratorPlannerLaunch.bridgeFlag where arguments.count == 2:
    await runBridge(path: arguments[1])
case nil:
    await runStandalone()
default:
    fail("usage: alethe-orchestrator-mcp [--bridge <file>]", code: 64)
}
exit(0)
