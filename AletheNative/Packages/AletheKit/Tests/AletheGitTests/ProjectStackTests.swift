import Foundation
import Testing
@testable import AletheGit

/// Upstream `project_detector.rs` test cases, with the suggested commands they imply (P5-5).
struct ProjectStackTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "alethe-detect-\(UUID().uuidString)")
        for (path, contents) in files {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func detectsTauriDesktopByConfPresence() throws {
        let root = try folder(["src-tauri/tauri.conf.json": "{}", "package.json": #"{"scripts":{"dev":"vite"}}"#])
        let detection = try ProjectStackDetector.detect(root)
        #expect(detection.stack == .desktop)
        #expect(detection.hasTauri)
        #expect(detection.suggestedCommands == ["npm run build", "cargo check --manifest-path src-tauri/Cargo.toml"])
    }

    @Test func detectsPlainNodeWebProject() throws {
        let root = try folder(["package.json": #"{"scripts":{"dev":"vite","build":"vite build"},"dependencies":{"react":"18.0.0"}}"#])
        let detection = try ProjectStackDetector.detect(root)
        #expect(detection.stack == .web)
        #expect(detection.hasFrontend)
        #expect(!detection.hasBackend)
        #expect(detection.suggestedCommands == ["npm run build"])
    }

    @Test func frontendDependencyAloneIsASignal() throws {
        let root = try folder(["package.json": #"{"devDependencies":{"svelte":"4"}}"#])
        #expect(try ProjectStackDetector.detect(root).stack == .web)
    }

    @Test func packageWithoutSignalIsNotFrontend() throws {
        let root = try folder(["package.json": #"{"name":"lib","dependencies":{"lodash":"4"}}"#])
        #expect(try ProjectStackDetector.detect(root).stack == .unknown)
    }

    @Test func detectsPythonBackendAsCli() throws {
        let root = try folder(["requirements.txt": "fastapi\n"])
        let detection = try ProjectStackDetector.detect(root)
        #expect(detection.stack == .cli)
        #expect(detection.hasBackend)
        #expect(!detection.hasFrontend)
        #expect(detection.suggestedCommands == ["python -m py_compile ."])
    }

    @Test func rustAndGoCliCommandsInUpstreamOrder() throws {
        let root = try folder(["Cargo.toml": "[package]\n", "go.mod": "module x\n"])
        #expect(try ProjectStackDetector.detect(root).suggestedCommands == ["cargo check", "go build ./..."])
    }

    @Test func detectsFullstackWhenBothPresent() throws {
        let root = try folder([
            "package.json": #"{"scripts":{"dev":"vite"},"dependencies":{"react":"18.0.0"}}"#,
            "pyproject.toml": "[project]\nname = \"x\"\n",
        ])
        let detection = try ProjectStackDetector.detect(root)
        #expect(detection.stack == .fullstack)
        #expect(detection.suggestedCommands == ["npm run build", "python -m py_compile ."])
    }

    @Test func rootTauriConfIsDesktopAndCargoIsNotABackend() throws {
        let root = try folder(["tauri.conf.json": "{}", "Cargo.toml": "[package]\n"])
        let detection = try ProjectStackDetector.detect(root)
        #expect(detection.stack == .desktop)
        #expect(!detection.hasBackend)
    }

    @Test func unknownWhenNothingRecognized() throws {
        let root = try folder(["README.md": "hello\n"])
        let detection = try ProjectStackDetector.detect(root)
        #expect(detection.stack == .unknown)
        #expect(detection.suggestedCommands.isEmpty)
    }

    @Test func missingFolderErrors() {
        #expect(throws: ProjectStackDetector.Failure.folderNotFound) {
            try ProjectStackDetector.detect(URL(filePath: "/definitely-not-a-real-path-xyz"))
        }
    }
}
