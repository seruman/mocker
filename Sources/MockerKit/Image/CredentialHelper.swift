import Foundation
import ContainerizationOCI

/// Registry credentials from Docker-style credential helpers named in `~/.mocker/config.json`.
///
/// The file takes Docker's `credHelpers` map, from registry host to helper suffix:
///
///     { "credHelpers": { "123456789012.dkr.ecr.us-east-1.amazonaws.com": "ecr-login" } }
///
/// For a listed host, mocker runs `docker-credential-<suffix> get` with the host on stdin and
/// reads `{"Username": ..., "Secret": ...}` back, the way Docker does. A listed host uses only
/// its helper: a helper that has no credentials means an anonymous request, and any other
/// failure fails the request.
enum CredentialHelper {
    struct HelperError: Error, CustomStringConvertible {
        let description: String
    }

    /// What a configured helper gave for a host.
    enum Lookup: Sendable {
        /// The host is not in `credHelpers`.
        case notConfigured
        /// The helper ran and has no credentials for the host.
        case anonymous
        case credentials(username: String, secret: String)
    }

    /// The message a helper prints, with a failing exit, when it has no credentials.
    static let notFoundMessage = "credentials not found in native keychain"

    /// Docker's username for an identity token, which mocker cannot use.
    static let identityTokenUsername = "<token>"

    /// Docker Hub's host as pull and push look it up, and the server URL Docker asks helpers for.
    static let dockerHubHost = "registry-1.docker.io"
    static let dockerHubServerURL = "https://index.docker.io/v1/"

    static var configPath: String {
        "\(MockerConfig.defaultDataRoot)/config.json"
    }

    private static let cache = CredentialHelperCache()

    /// What the configured helper of `host` gives, `.notConfigured` when it has none.
    /// Throws when the config file cannot be read or the helper fails.
    /// Each host's helper runs once per run, or again after it fails.
    static func authentication(for host: String) async throws -> Lookup {
        try await cache.lookup(host: host) {
            guard let helper = try loadHelpers(path: configPath)[host] else {
                return .notConfigured
            }

            return try await get(host: host, helper: helper, runner: RealCredentialHelperRunner())
        }
    }

    /// The `credHelpers` map of the config file at `path`, empty when there is no file.
    /// Keys are turned into the hosts pull and push look up, the way `mocker login` saves them,
    /// so `docker.io`, `index.docker.io` and `https://index.docker.io/v1/` all mean Docker Hub.
    static func loadHelpers(path: String) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw HelperError(description: "reading \(path): \(error.localizedDescription)")
        }

        let configured: [String: String]
        do {
            configured = try JSONDecoder().decode(ConfigFile.self, from: data).credHelpers ?? [:]
        } catch {
            throw HelperError(description: "parsing \(path): \(error)")
        }

        var helpers: [String: String] = [:]
        for (server, helper) in configured {
            let host = RegistryAuth.hostname(for: server)
            if let existing = helpers[host], existing != helper {
                throw HelperError(description: "\(path): credHelpers sets both \(existing) and \(helper) for \(host)")
            }
            helpers[host] = helper
        }
        return helpers
    }

    /// Ask `docker-credential-<helper>` for the credentials of `host`.
    /// Docker Hub is asked for as `https://index.docker.io/v1/`, the key Docker uses, so
    /// credentials a helper stored for `docker login` are found.
    static func get(host: String, helper: String, runner: CredentialHelperRunning) async throws -> Lookup {
        let program = "docker-credential-\(helper)"
        let serverURL = host == dockerHubHost ? dockerHubServerURL : host
        let result = try await runner.run(program: program, arguments: ["get"], input: serverURL)
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard result.status == 0 else {
            if output == notFoundMessage {
                return .anonymous
            }

            let detail = output.isEmpty ? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : output
            throw HelperError(description: "\(program) get for \(host) failed (exit \(result.status)): \(detail)")
        }

        let response: HelperResponse
        do {
            response = try JSONDecoder().decode(HelperResponse.self, from: Data(output.utf8))
        } catch {
            throw HelperError(description: "\(program) get for \(host) printed invalid JSON: \(error)")
        }

        guard response.Username != identityTokenUsername else {
            throw HelperError(description: "\(program) get for \(host) returned an identity token, which mocker does not support")
        }

        return .credentials(username: response.Username, secret: response.Secret)
    }

    private struct ConfigFile: Decodable {
        let credHelpers: [String: String]?
    }

    private struct HelperResponse: Decodable {
        let Username: String
        let Secret: String
    }
}

/// One lookup per host per run, shared by concurrent pulls. A failed lookup is not kept,
/// so the next pull runs the helper again.
actor CredentialHelperCache {
    private var tasks: [String: Task<CredentialHelper.Lookup, Error>] = [:]

    func lookup(
        host: String,
        fetch: @escaping @Sendable () async throws -> CredentialHelper.Lookup
    ) async throws -> CredentialHelper.Lookup {
        if let task = tasks[host] {
            return try await task.value
        }

        let task = Task { try await fetch() }
        tasks[host] = task

        do {
            return try await task.value
        } catch {
            if tasks[host] == task {
                tasks[host] = nil
            }
            throw error
        }
    }
}

/// Runs a credential helper, found on PATH, with `input` on its stdin.
protocol CredentialHelperRunning: Sendable {
    func run(program: String, arguments: [String], input: String) async throws -> (stdout: String, stderr: String, status: Int32)
}

struct RealCredentialHelperRunner: CredentialHelperRunning {
    func run(program: String, arguments: [String], input: String) async throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdin = stdinPipe.fileHandleForWriting
        // A helper that exits without reading its input must not kill mocker with SIGPIPE.
        _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        let outTask = Task.detached { outHandle.readDataToEndOfFile() }
        let errTask = Task.detached { errHandle.readDataToEndOfFile() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
                return
            }

            try? stdin.write(contentsOf: Data(input.utf8))
            try? stdin.close()
        }

        let out = String(data: await outTask.value, encoding: .utf8) ?? ""
        let err = String(data: await errTask.value, encoding: .utf8) ?? ""
        return (out, err, status)
    }
}
