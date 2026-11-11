import Foundation
import Testing
@testable import MockerKit

@Suite("CredentialHelper")
struct CredentialHelperTests {

    private actor StubRunner: CredentialHelperRunning {
        struct Call: Sendable {
            let program: String
            let arguments: [String]
            let input: String
        }

        private(set) var calls: [Call] = []
        private let stdout: String
        private let stderr: String
        private let status: Int32

        init(stdout: String = "", stderr: String = "", status: Int32 = 0) {
            self.stdout = stdout
            self.stderr = stderr
            self.status = status
        }

        func run(program: String, arguments: [String], input: String) async throws -> (stdout: String, stderr: String, status: Int32) {
            calls.append(Call(program: program, arguments: arguments, input: input))
            return (stdout, stderr, status)
        }
    }

    private static let host = "123456789012.dkr.ecr.us-east-1.amazonaws.com"

    private func writeConfig(_ contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mocker-credhelper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.json").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("a missing config file configures no helpers")
    func missingConfigFile() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mocker-credhelper-\(UUID().uuidString)/config.json").path

        #expect(try CredentialHelper.loadHelpers(path: path).isEmpty)
    }

    @Test("credHelpers are read, and other keys are ignored")
    func readsCredHelpers() throws {
        let path = try writeConfig("""
        {"auths": {"ghcr.io": {}}, "credHelpers": {"\(Self.host)": "ecr-login"}}
        """)

        #expect(try CredentialHelper.loadHelpers(path: path) == [Self.host: "ecr-login"])
    }

    @Test("a config file without credHelpers configures no helpers")
    func noCredHelpersKey() throws {
        let path = try writeConfig("{}")

        #expect(try CredentialHelper.loadHelpers(path: path).isEmpty)
    }

    @Test("Docker Hub keys mean the host pull looks up", arguments: [
        "docker.io",
        "index.docker.io",
        "https://index.docker.io/v1/",
        "registry-1.docker.io",
    ])
    func normalizesDockerHub(key: String) throws {
        let path = try writeConfig(#"{"credHelpers": {"\#(key)": "osxkeychain"}}"#)

        #expect(try CredentialHelper.loadHelpers(path: path) == ["registry-1.docker.io": "osxkeychain"])
    }

    @Test("a scheme and path on a key are dropped")
    func normalizesURLKey() throws {
        let path = try writeConfig(#"{"credHelpers": {"https://\#(Self.host)/v2/": "ecr-login"}}"#)

        #expect(try CredentialHelper.loadHelpers(path: path) == [Self.host: "ecr-login"])
    }

    @Test("two keys for one host with different helpers are an error")
    func conflictingKeys() throws {
        let path = try writeConfig(#"{"credHelpers": {"docker.io": "osxkeychain", "index.docker.io": "desktop"}}"#)

        #expect(throws: CredentialHelper.HelperError.self) {
            try CredentialHelper.loadHelpers(path: path)
        }
    }

    @Test("an invalid config file is an error")
    func invalidConfigFile() throws {
        let path = try writeConfig("{not json")

        #expect(throws: CredentialHelper.HelperError.self) {
            try CredentialHelper.loadHelpers(path: path)
        }
    }

    @Test("get runs docker-credential-<helper> get with the host on stdin")
    func getRunsHelper() async throws {
        let runner = StubRunner(stdout: #"{"ServerURL": "\#(Self.host)", "Username": "AWS", "Secret": "s3cret"}"#)

        let lookup = try await CredentialHelper.get(host: Self.host, helper: "ecr-login", runner: runner)

        let calls = await runner.calls
        #expect(calls.map(\.program) == ["docker-credential-ecr-login"])
        #expect(calls.map(\.arguments) == [["get"]])
        #expect(calls.map(\.input) == [Self.host])

        guard case .credentials(let username, let secret) = lookup else {
            Issue.record("expected credentials, got \(lookup)")
            return
        }
        #expect(username == "AWS")
        #expect(secret == "s3cret")
    }

    @Test("Docker Hub is asked for by Docker's server URL")
    func dockerHubServerURL() async throws {
        let runner = StubRunner(stdout: #"{"Username": "me", "Secret": "pw"}"#)

        _ = try await CredentialHelper.get(host: "registry-1.docker.io", helper: "osxkeychain", runner: runner)

        #expect(await runner.calls.map(\.input) == ["https://index.docker.io/v1/"])
    }

    @Test("a helper without credentials means an anonymous request")
    func notFoundIsAnonymous() async throws {
        let runner = StubRunner(stdout: "credentials not found in native keychain\n", status: 1)

        let lookup = try await CredentialHelper.get(host: Self.host, helper: "osxkeychain", runner: runner)

        guard case .anonymous = lookup else {
            Issue.record("expected anonymous, got \(lookup)")
            return
        }
    }

    @Test("a failing helper is an error that carries its output")
    func failingHelper() async throws {
        let runner = StubRunner(stderr: "env: docker-credential-nope: No such file or directory\n", status: 127)

        do {
            _ = try await CredentialHelper.get(host: Self.host, helper: "nope", runner: runner)
            Issue.record("expected an error")
        } catch let error as CredentialHelper.HelperError {
            #expect(error.description.contains("No such file or directory"))
            #expect(error.description.contains("exit 127"))
        }
    }

    @Test("invalid JSON from a helper is an error")
    func invalidHelperOutput() async {
        let runner = StubRunner(stdout: "not json")

        await #expect(throws: CredentialHelper.HelperError.self) {
            try await CredentialHelper.get(host: Self.host, helper: "ecr-login", runner: runner)
        }
    }

    @Test("an identity token from a helper is an error")
    func identityToken() async {
        let runner = StubRunner(stdout: #"{"Username": "<token>", "Secret": "refresh"}"#)

        await #expect(throws: CredentialHelper.HelperError.self) {
            try await CredentialHelper.get(host: Self.host, helper: "desktop", runner: runner)
        }
    }

    @Test("concurrent lookups of one host run its helper once")
    func lookupOncePerHost() async throws {
        let cache = CredentialHelperCache()
        let runner = StubRunner(stdout: #"{"Username": "AWS", "Secret": "s3cret"}"#)
        let fetch: @Sendable () async throws -> CredentialHelper.Lookup = {
            try await CredentialHelper.get(host: Self.host, helper: "ecr-login", runner: runner)
        }

        async let first = cache.lookup(host: Self.host, fetch: fetch)
        async let second = cache.lookup(host: Self.host, fetch: fetch)
        _ = try await (first, second)
        _ = try await cache.lookup(host: Self.host, fetch: fetch)

        #expect(await runner.calls.count == 1)
    }

    @Test("a failed lookup is not cached, so the next one runs the helper again")
    func failedLookupNotCached() async throws {
        let cache = CredentialHelperCache()
        let runner = StubRunner(stdout: "boom", status: 1)
        let fetch: @Sendable () async throws -> CredentialHelper.Lookup = {
            try await CredentialHelper.get(host: Self.host, helper: "ecr-login", runner: runner)
        }

        for _ in 0..<2 {
            await #expect(throws: CredentialHelper.HelperError.self) {
                try await cache.lookup(host: Self.host, fetch: fetch)
            }
        }

        #expect(await runner.calls.count == 2)
    }

    @Test("the real runner passes the input on stdin and keeps stdout and stderr apart")
    func realRunner() async throws {
        let runner = RealCredentialHelperRunner()

        let echoed = try await runner.run(program: "cat", arguments: [], input: Self.host)
        #expect(echoed.stdout == Self.host)
        #expect(echoed.status == 0)

        let failed = try await runner.run(program: "sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], input: "")
        #expect(failed.stdout == "out\n")
        #expect(failed.stderr == "err\n")
        #expect(failed.status == 3)
    }
}
