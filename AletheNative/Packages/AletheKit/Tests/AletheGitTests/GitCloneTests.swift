import Foundation
import Testing
@testable import AletheGit

/// Clone URL handling and `git clone` of a local bare repository (P5-5).
struct GitCloneTests {
    @Test(arguments: [
        ("owner/repo", "https://github.com/owner/repo"),
        ("  github.com/owner/repo  ", "https://github.com/owner/repo"),
        ("https://gitlab.com/a/b.git", "https://gitlab.com/a/b.git"),
        ("http://host/a/b", "http://host/a/b"),
        ("git@github.com:owner/repo.git", "git@github.com:owner/repo.git"),
        ("ssh://git@host/a/b", "ssh://git@host/a/b"),
        ("/tmp/origin.git", "/tmp/origin.git"),
        ("file:///tmp/origin.git", "file:///tmp/origin.git"),
        ("not a url", "not a url"),
        ("plain", "plain"),
    ])
    func normalizesLikeUpstream(raw: String, expected: String) {
        #expect(GitCloneURL.normalize(raw) == expected)
    }

    @Test func refusesOptionsAndHelperTransports() {
        #expect(GitCloneURL.isCloneable("https://github.com/a/b"))
        #expect(GitCloneURL.isCloneable("git@github.com:a/b.git"))
        #expect(GitCloneURL.isCloneable("/tmp/origin.git"))
        #expect(!GitCloneURL.isCloneable("--upload-pack=touch /tmp/x"))
        #expect(!GitCloneURL.isCloneable("ext::sh -c touch% /tmp/pwned"))
        #expect(!GitCloneURL.isCloneable("plain"))
        #expect(!GitCloneURL.isCloneable(""))
    }

    @Test(arguments: [
        ("https://github.com/owner/repo", "repo"),
        ("https://github.com/owner/repo.git/", "repo"),
        ("git@github.com:owner/my-app.git", "my-app"),
        ("https://github.com/owner/we ird", "we_ird"),
        ("https://github.com/owner/..", "repo"),
        ("", "repo"),
    ])
    func folderNameIsSanitized(url: String, expected: String) {
        #expect(GitCloneURL.folderName(for: url) == expected)
    }

    @Test func targetDefaultsToHomeAletheAndKeepsANamedFolder() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let url = "https://github.com/owner/repo"
        #expect(GitCloneURL.target(requested: "", url: url, home: home).path == "/Users/me/Alethe/repo")
        #expect(GitCloneURL.target(requested: "/work", url: url, home: home).path == "/work/repo")
        #expect(GitCloneURL.target(requested: "/work/repo", url: url, home: home).path == "/work/repo")
        #expect(GitCloneURL.target(requested: "~/code", url: url, home: home).path == "/Users/me/code/repo")
    }

    @Test(arguments: [
        ("git@github.com:owner/repo.git", "https://github.com/owner/repo"),
        ("https://token@github.com/owner/repo.git", "https://github.com/owner/repo"),
        ("ssh://git@gitlab.com/group/sub/repo", "https://gitlab.com/group/sub/repo"),
        ("https://github.com/owner/repo/", "https://github.com/owner/repo"),
    ])
    func webURLOfRemotes(remote: String, expected: String) {
        #expect(GitCloneURL.webURL(forRemote: remote)?.absoluteString == expected)
    }

    @Test func localRemotesHaveNoWebURL() {
        #expect(GitCloneURL.webURL(forRemote: "/tmp/origin.git") == nil)
        #expect(GitCloneURL.webURL(forRemote: "file:///tmp/origin.git") == nil)
    }

    @Test func parsesProgressLines() {
        #expect(GitCloneProgress.parse("Receiving objects:  45% (450/1000)") == GitCloneProgress(phase: "Receiving objects", percent: 45))
        #expect(GitCloneProgress.parse("remote: Counting objects: 100% (3/3), done.") == GitCloneProgress(phase: "Counting objects", percent: 100))
        #expect(GitCloneProgress.parse("Cloning into '/tmp/x'...") == nil)
    }

    @Test func clonesALocalBareRepository() async throws {
        let source = try await TempRepo()
        let bare = FileManager.default.temporaryDirectory.appending(path: "alethe-bare-\(UUID().uuidString).git").resolvingSymlinksInPath()
        _ = try await TempRepo.runner.run(["clone", "--bare", "--", source.url.path, bare.path], in: source.url)
        let parent = FileManager.default.temporaryDirectory.appending(path: "alethe-clones-\(UUID().uuidString)").resolvingSymlinksInPath()
        let target = GitCloneURL.target(requested: parent.path, url: bare.path)

        let cloned = try await GitCloner(runner: TempRepo.runner).clone(bare.path, into: target)
        #expect(cloned.lastPathComponent == GitCloneURL.folderName(for: bare.path))
        #expect(FileManager.default.fileExists(atPath: cloned.appending(path: "README.md").path))
    }

    @Test func failedCloneRemovesThePartialFolder() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "alethe-clones-\(UUID().uuidString)")
        let target = parent.appending(path: "missing")
        await #expect(throws: GitError.self) {
            try await GitCloner(runner: TempRepo.runner).clone("/definitely/not/a/repo.git", into: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func refusesANonEmptyTarget() async throws {
        let repo = try await TempRepo()
        await #expect(throws: GitCloneError.targetExists(repo.url.standardizedFileURL.path)) {
            try await GitCloner(runner: TempRepo.runner).clone("https://github.com/a/b", into: repo.url)
        }
    }

    @Test func refusesAnOptionAsURL() async {
        let target = FileManager.default.temporaryDirectory.appending(path: "alethe-clones-\(UUID().uuidString)/x")
        await #expect(throws: GitCloneError.invalidURL("--help")) {
            try await GitCloner(runner: TempRepo.runner).clone("--help", into: target)
        }
    }
}
