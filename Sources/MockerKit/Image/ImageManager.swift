import Foundation
import Containerization
import ContainerizationOCI

/// Manages container images using Apple's Containerization framework.
public actor ImageManager {
    private let imageStore: Containerization.ImageStore
    private let storePath: URL

    public init(config: MockerConfig = MockerConfig()) throws {
        self.imageStore = try Containerization.ImageStore(path: config.ociStorePath)
        self.storePath = config.ociStorePath
    }

    // MARK: - Pull

    /// Pull an image from a registry.
    /// Returns (image, alreadyExisted) so the CLI can show the right status message.
    /// - Parameter platform: optional `linux/amd64`-style filter; nil pulls the full manifest list.
    public func pull(_ reference: String, platform: String? = nil) async throws -> (ImageInfo, Bool) {
        let normalized = try Self.normalize(reference)
        let parsedPlatform = try platform.map { try ContainerizationOCI.Platform(from: $0) }

        // Only short-circuit when the caller did not request a specific platform —
        // a platform-filtered pull may need to fetch additional descriptors that
        // the existing entry does not cover.
        if parsedPlatform == nil,
           let existing = try? await imageStore.get(reference: normalized) {
            return (await Self.toImageInfo(existing), true)
        }

        let auth = try await RegistryAuth.resolve(for: normalized)
        let image = try await imageStore.pull(reference: normalized, platform: parsedPlatform, auth: auth)
        return (await Self.toImageInfo(image), false)
    }

    // MARK: - List

    /// List all local images — merges Apple CLI store with our OCI store.
    /// - Parameter enrich: resolve each image's real SIZE/CREATED. Costs a manifest and
    ///   config read per image, so callers that only compare repository and tag pass false.
    public func list(enrich: Bool = true) async throws -> [ImageInfo] {
        // Primary: Apple CLI store (includes pulled and built images)
        let cliImages = try await listFromCLI(enrich: enrich)
        if !cliImages.isEmpty { return Self.hidingNamedDangling(cliImages) }

        // Fallback: our OCI store
        let images = try await imageStore.list()
        var infos: [ImageInfo] = []
        for image in images {
            infos.append(enrich ? await Self.toImageInfo(image) : Self.basicImageInfo(image))
        }
        return Self.hidingNamedDangling(infos)
    }

    private func listFromCLI(enrich: Bool) async throws -> [ImageInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.containerCLI)
        process.arguments = ["images", "ls"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let output = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }

        let parsed = parseCLIImageList(output)
        return enrich ? await self.enrich(parsed) : parsed.map(\.info)
    }

    /// Fill in SIZE and CREATED for a CLI-derived listing.
    ///
    /// `container images ls` prints only NAME/TAG/DIGEST, so the values come from each
    /// image's manifest and config in the shared content store. An image missing from
    /// the store keeps its unknown (nil) values rather than a fabricated zero.
    private func enrich(_ images: [(info: ImageInfo, reference: String)]) async -> [ImageInfo] {
        var result: [ImageInfo] = []
        result.reserveCapacity(images.count)
        for (info, reference) in images {
            let listedDigest = info.id.replacingOccurrences(of: ".", with: "")
            guard let image = try? await resolve(reference),
                  image.digest.hasPrefix(listedDigest) || listedDigest.hasPrefix(image.digest) else {
                // No match, or a different image happens to answer to that reference —
                // leave the values unknown rather than attaching another image's metadata.
                result.append(info)
                continue
            }
            var enriched = info
            let metadata = await Self.sizeAndCreated(of: image)
            enriched.size = metadata.size
            enriched.created = metadata.created
            result.append(enriched)
        }
        return result
    }

    /// Rows of the CLI listing, each with the reference exactly as the CLI printed it —
    /// a locally built image is stored under that bare reference, not the display form.
    private func parseCLIImageList(_ output: String) -> [(info: ImageInfo, reference: String)] {
        var results: [(info: ImageInfo, reference: String)] = []
        let lines = output.components(separatedBy: "\n").dropFirst() // skip header
        for line in lines {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3 else { continue }
            let name = cols[0]
            let tag = cols[1]
            let digest = "sha256:" + cols[2]
            if Self.isDanglingReference("\(name):\(tag)") {
                // The CLI prints a digest-only name without its digest, so find it by ID.
                results.append((ImageInfo(id: digest, repository: "<none>", tag: "<none>"), cols[2]))
                continue
            }
            let repo = name.contains(".") || name.contains("/") ? name : "docker.io/library/\(name)"
            results.append((ImageInfo(id: digest, repository: repo, tag: tag), "\(name):\(tag)"))
        }
        return results
    }

    // MARK: - Remove

    /// Remove an image by reference.
    public func remove(_ reference: String) async throws -> ImageInfo {
        let image = try await resolve(reference)
        let info = await Self.toImageInfo(image)
        // Delete the reference that actually matched, never a re-derived one.
        try await imageStore.delete(reference: image.reference)
        return info
    }

    // MARK: - Tag

    /// Tag an image with a new reference.
    public func tag(_ source: String, _ target: String) async throws {
        let image = try await resolve(source)
        let dst = try Self.normalize(target)
        _ = try await imageStore.tag(existing: image.reference, new: dst)

        // A named image is no longer dangling, as in Docker.
        try await dropDanglingReference(digest: image.digest)
    }

    /// Drop the dangling placeholder of `digest`, once something names the image.
    /// Checked first so that the store's state file is only rewritten when it changes.
    private func dropDanglingReference(digest: String) async throws {
        let reference = Self.danglingReference(digest: digest)
        guard (try? await imageStore.get(reference: reference)) != nil else { return }
        try await imageStore.delete(reference: reference)
    }

    // MARK: - Dangling images

    /// Repository an untagged build is stored under. Apple's store keeps every image
    /// under a name, so `mocker build` without `-t` stores the image as
    /// `mocker-dangling@<digest>` and mocker shows it as `<none>:<none>`, the way Docker's
    /// containerd image store uses `moby-dangling@<digest>`.
    static let danglingName = "mocker-dangling"

    /// The placeholder name of the dangling image with `digest`. Named by digest so that
    /// rebuilding the same image untagged leaves one `<none>` entry, as in Docker.
    static func danglingReference(digest: String) -> String {
        "docker.io/library/\(danglingName)@\(digest)"
    }

    /// The throwaway name an untagged build runs under until it is renamed to its digest.
    static func temporaryBuildReference() -> String {
        "\(danglingName):build-\(UUID().uuidString.lowercased())"
    }

    /// Whether `reference` is a dangling placeholder, or a throwaway build name left
    /// behind by an interrupted untagged build, which is just as nameless.
    static func isDanglingReference(_ reference: String) -> Bool {
        let library = "docker.io/library/"
        let name = reference.hasPrefix(library) ? String(reference.dropFirst(library.count)) : reference
        return name.hasPrefix("\(danglingName)@") || name.hasPrefix("\(danglingName):")
    }

    /// Listing without the dangling entries of images that also have a name, and with
    /// one entry per dangling image. Docker shows an image as `<none>` only when nothing
    /// else names it.
    static func hidingNamedDangling(_ images: [ImageInfo]) -> [ImageInfo] {
        let named = Set(images.filter { !$0.isDangling }.map(\.id))
        var seen: Set<String> = []
        return images.filter { image in
            guard image.isDangling else { return true }
            return !named.contains(image.id) && seen.insert(image.id).inserted
        }
    }

    /// Whether a container started from one of `containerImages` uses the image stored
    /// as `reference` with `digest`. A container records the image the way it was given,
    /// which for a dangling image is its ID or a prefix of it.
    static func isUsed(reference: String, digest: String, byContainerImages containerImages: [String]) -> Bool {
        let hex = digestBody(digest).lowercased()
        return containerImages.contains { image in
            image == reference || (looksLikeDigest(image) && hex.hasPrefix(digestBody(image).lowercased()))
        }
    }

    /// Remove the dangling images no container uses, as `docker image prune` does.
    /// - Parameter containerImages: the image of every existing container.
    /// - Returns: the IDs of the removed images and the bytes freed on disk.
    public func pruneDangling(containerImages: [String]) async throws -> (deleted: [String], reclaimed: UInt64) {
        let stored = try await imageStore.list()
        let named = Set(stored.filter { !Self.isDanglingReference($0.reference) }.map(\.digest))
        let unused = stored.filter {
            Self.isDanglingReference($0.reference)
                && !Self.isUsed(reference: $0.reference, digest: $0.digest, byContainerImages: containerImages)
        }
        guard !unused.isEmpty else { return ([], 0) }

        // Delete through the runtime: it also removes the blobs nothing references any
        // more, under the same lock its pulls and builds hold, which this process can't take.
        let before = blobsSize()
        let (output, exitCode) = try await runContainerCLI(["image", "delete"] + unused.map(\.reference))
        guard exitCode == 0 else {
            throw MockerError.operationFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let after = blobsSize()

        var deleted: [String] = []
        for image in unused where !named.contains(image.digest) && !deleted.contains(image.digest) {
            deleted.append(image.digest)
        }
        return (deleted, before > after ? before - after : 0)
    }

    /// Total size of the blobs in the content store.
    private func blobsSize() -> UInt64 {
        let blobs = storePath.appendingPathComponent("content/blobs/sha256")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: blobs, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files.reduce(0) { total, file in
            total + UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func runContainerCLI(_ arguments: [String]) async throws -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.containerCLI)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (String(data: data, encoding: .utf8) ?? "", p.terminationStatus))
            }
        }
    }

    // MARK: - Inspect

    /// Inspect an image reference, returning a Docker-compatible ImageInspect.
    public func inspect(_ reference: String, platform: String? = nil) async throws -> ImageInspect {
        let image = try await resolve(reference)
        let normalized = image.reference
        let resolvedPlatform: ContainerizationOCI.Platform
        if let platformString = platform {
            resolvedPlatform = try ContainerizationOCI.Platform(from: platformString)
        } else {
            resolvedPlatform = ContainerizationOCI.Platform.current
        }

        let manifest: ContainerizationOCI.Manifest
        let config: ContainerizationOCI.Image
        let configExtras: ImageInspectConfigExtras
        if let matched = try? await image.manifest(for: resolvedPlatform) {
            manifest = matched
            let configContent = try await image.getContent(digest: matched.config.digest)
            config = try configContent.decode()
            configExtras = try decodeImageInspectConfigExtras(from: configContent.data())
        } else {
            // No exact platform match: a single-arch or sole-manifest image is still
            // inspectable — Docker returns its only manifest. Multi-manifest indexes
            // with no match remain a genuine error.
            let index = try await image.index()
            guard let sole = Self.soleManifestDescriptor(from: index.manifests) else {
                throw MockerError.operationFailed(
                    "platform \(resolvedPlatform.description) not available for image \(reference)")
            }
            manifest = try await image.getContent(digest: sole.digest).decode()
            let configContent = try await image.getContent(digest: manifest.config.digest)
            config = try configContent.decode()
            configExtras = try decodeImageInspectConfigExtras(from: configContent.data())
        }
        let repoMetadata = await repoMetadata(for: image, fallbackReference: normalized)
        return mapToImageInspect(
            config: config,
            manifest: manifest,
            reference: normalized,
            indexDigest: image.digest,
            configExtras: configExtras,
            repoTags: repoMetadata.tags,
            repoDigests: repoMetadata.digests
        )
    }

    private func repoMetadata(
        for image: Containerization.Image,
        fallbackReference: String
    ) async -> (tags: [String], digests: [String]) {
        let images = (try? await imageStore.list()) ?? [image]
        return Self.repoMetadata(for: image, localImages: images, fallbackReference: fallbackReference)
    }

    static func repoMetadata(
        for image: Containerization.Image,
        localImages images: [Containerization.Image],
        fallbackReference: String
    ) -> (tags: [String], digests: [String]) {
        let matchingReferences = images
            .filter { $0.digest == image.digest }
            .map(\.reference)
            .sorted()
        let references = (matchingReferences.isEmpty ? [image.reference, fallbackReference] : matchingReferences)
            .filter { !isDanglingReference($0) }

        let tags = Set(references.compactMap(Self.repoTag(from:))).sorted()
        // Containerization exposes local references and the image's root descriptor digest,
        // but not a registry-provided list of repo digest aliases. Report only repos found
        // in local references that point at this exact stored descriptor.
        let digests = Set(references.map { "\(Self.repositoryName(from: $0))@\(image.digest)" })
            .sorted()

        return (tags, digests)
    }

    private static func referenceHasTag(_ reference: String) -> Bool {
        let beforeDigest = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        let lastComponent = beforeDigest
            .split(separator: "/", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? beforeDigest
        return lastComponent.contains(":")
    }

    private static func repoTag(from reference: String) -> String? {
        let beforeDigest = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        return referenceHasTag(beforeDigest) ? beforeDigest : nil
    }

    private static func repositoryName(from reference: String) -> String {
        let withoutDigest = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        var parts = withoutDigest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if var last = parts.last, let colonIndex = last.lastIndex(of: ":") {
            last = String(last[last.startIndex..<colonIndex])
            parts[parts.count - 1] = last
        }
        return parts.joined(separator: "/")
    }

    /// Returns the only manifest descriptor when an index has exactly one, enabling
    /// single-arch images to be inspected even if their platform differs from the
    /// requested one. Returns nil for empty or multi-manifest indexes.
    static func soleManifestDescriptor(
        from manifests: [ContainerizationOCI.Descriptor]
    ) -> ContainerizationOCI.Descriptor? {
        manifests.count == 1 ? manifests.first : nil
    }

    // MARK: - Build

    private static let containerCLI = CLIResolver.resolve()

    /// Construct the argument vector for `container build`.
    ///
    /// Pure and side-effect-free so it can be unit-tested without spawning a
    /// process. The `builder` value maps to `container build --builder`, the
    /// manual escape hatch for exotic architectures (ppc64le/s390x/riscv64) that
    /// the local arm64 BuildKit VM cannot emulate — see README and apple/container#1496.
    static func makeBuildArguments(
        tags: [String], dockerfilePath: String, context: String, noCache: Bool = false,
        buildArgs: [String] = [], platforms: [String] = [], target: String? = nil,
        labels: [String] = [], progress: String? = nil,
        output: [String] = [], builder: String? = nil, ssh: [String] = []
    ) -> [String] {
        var args = ["build"]
        for t in tags { args += ["-t", t] }
        args += ["-f", dockerfilePath]
        if noCache { args.append("--no-cache") }
        for arg in buildArgs { args += ["--build-arg", arg] }
        for p in platforms { args += ["--platform", p] }
        if let target { args += ["--target", target] }
        for l in labels { args += ["-l", l] }
        if let progress { args += ["--progress", progress] }
        for o in output { args += ["-o", o] }
        if let builder, !builder.isEmpty { args += ["--builder", builder] }
        for s in ssh { args += ["--ssh", s] }
        args.append(context)
        return args
    }

    /// Resolve a build `context` to an absolute path anchored to `cwd`.
    public static func resolveContextPath(context: String, cwd: String) -> String {
        guard !context.hasPrefix("/") else { return context }
        return URL(fileURLWithPath: cwd).appendingPathComponent(context).standardized.path
    }

    static func resolveDockerfilePath(context: String, dockerfile: String?, cwd: String) -> String {
        guard let dockerfile else {
            return URL(fileURLWithPath: context).appendingPathComponent("Dockerfile").standardized.path
        }
        if dockerfile.hasPrefix("/") {
            return dockerfile
        }
        return URL(fileURLWithPath: cwd).appendingPathComponent(dockerfile).standardized.path
    }

    /// Resolve a Compose service's `build.dockerfile` to an absolute path using Docker Compose semantics:
    /// relative `dockerfile` is relative to `build.context`, not the CWD.
    public static func composeDockerfilePath(context: String, dockerfile: String, cwd: String) -> String {
        let absContext = resolveContextPath(context: context, cwd: cwd)
        return resolveDockerfilePath(context: absContext, dockerfile: dockerfile, cwd: absContext)
    }

    /// Build an image from a Dockerfile using the `container` CLI.
    /// - Parameter tags: names for the image. Without any the image is stored dangling,
    ///   reachable by its ID only, as `docker build` without `-t` does.
    /// - Parameter platforms: pass multiple values to build a multi-arch manifest list (e.g. `["linux/amd64", "linux/arm64"]`).
    /// - Parameter builder: optional named builder instance forwarded to `container build --builder`,
    ///   enabling a remote BuildKit node for exotic architectures (apple/container#1496).
    public func build(tags: [String], context: String, dockerfile: String? = nil, noCache: Bool = false, buildArgs: [String] = [], platforms: [String] = [], target: String? = nil, labels: [String] = [], quiet: Bool = false, progress: String? = nil, output: [String] = [], builder: String? = nil, ssh: [String] = []) async throws -> ImageInfo {
        let absContext = Self.resolveContextPath(context: context, cwd: FileManager.default.currentDirectoryPath)
        let dockerfilePath = Self.resolveDockerfilePath(
            context: absContext,
            dockerfile: dockerfile,
            cwd: FileManager.default.currentDirectoryPath
        )

        guard FileManager.default.fileExists(atPath: dockerfilePath) else {
            throw MockerError.buildError("Dockerfile not found at \(dockerfilePath)")
        }

        // `container build` needs a name to store the image under, so an untagged build
        // runs under a throwaway one that `keepDangling` replaces afterwards.
        let buildTags = tags.isEmpty ? [Self.temporaryBuildReference()] : tags
        let args = Self.makeBuildArguments(
            tags: buildTags, dockerfilePath: dockerfilePath, context: context, noCache: noCache,
            buildArgs: buildArgs, platforms: platforms, target: target, labels: labels,
            progress: progress, output: output, builder: builder, ssh: ssh
        )

        // `container build -q` never returns (apple/container#2387), so a quiet build runs
        // with its output kept in a file instead, shown only when the build fails.
        let log = quiet
            ? FileManager.default.temporaryDirectory.appendingPathComponent("mocker-build-\(UUID().uuidString).log")
            : nil
        defer {
            if let log { try? FileManager.default.removeItem(at: log) }
        }
        let sink: FileHandle
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            sink = try FileHandle(forWritingTo: log)
        } else {
            // Inherit the terminal so build progress is shown live. The runtime prints the
            // image names to stdout; send them to stderr so stdout carries only what
            // mocker prints.
            sink = FileHandle.standardError
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.containerCLI)
        process.arguments = args
        process.standardOutput = sink
        process.standardError = sink

        try process.run()

        let exitCode = await withCheckedContinuation { continuation in
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
        }
        if log != nil {
            try? sink.close()
        }

        guard exitCode == 0 else {
            if let log, let data = try? Data(contentsOf: log) {
                FileHandle.standardError.write(data)
            }
            throw MockerError.buildError("Build failed with exit code \(exitCode)")
        }

        // Fetch real image info from the store after build. `container build -t <tag>`
        // stores the literal tag, so this must resolve verbatim-first too.
        guard let image = try? await resolve(buildTags[0]) else {
            // The build succeeded but the image is not indexed in the store we can read.
            // Report what is known instead of inventing a digest, size and timestamp.
            let ref = try ImageReference.parse(buildTags[0])
            return ImageInfo(id: "", repository: ref.fullRepository, tag: ref.tag)
        }

        if tags.isEmpty {
            return try await keepDangling(image)
        }

        // A named image is no longer dangling, as in Docker.
        try await dropDanglingReference(digest: image.digest)
        return await Self.toImageInfo(image)
    }

    /// Move an untagged build from its throwaway name to its dangling placeholder. When
    /// another name already points at the same image (an untagged rebuild of a tagged
    /// image, fully cached), the image is not dangling, so only the throwaway name goes.
    private func keepDangling(_ image: Containerization.Image) async throws -> ImageInfo {
        let info = await Self.toImageInfo(image)

        let stored = try await imageStore.list()
        let named = stored.contains { $0.digest == image.digest && !Self.isDanglingReference($0.reference) }
        if !named {
            _ = try await imageStore.tag(existing: image.reference, new: Self.danglingReference(digest: image.digest))
        }
        try await imageStore.delete(reference: image.reference)

        return info
    }

    // MARK: - Push

    /// Push an image to a registry.
    /// - Parameter platform: optional `linux/amd64`-style filter; nil pushes the full manifest list.
    public func push(_ reference: String, platform: String? = nil) async throws {
        // The image is found the way the user spelled it (a local build is stored under
        // its bare tag), but the push target must be the registry-qualified reference —
        // it is also the key RegistryAuth resolves credentials with. Tag the local image
        // under that name first, otherwise the store has nothing to push.
        let image = try await resolve(reference)
        let normalized = try Self.normalize(reference)
        if image.reference != normalized {
            // Must not be swallowed: pushing after a failed tag would upload whatever
            // image that reference already points at.
            _ = try await imageStore.tag(existing: image.reference, new: normalized)
        }
        let parsedPlatform = try platform.map { try ContainerizationOCI.Platform(from: $0) }
        let auth = try await RegistryAuth.resolve(for: normalized)
        try await imageStore.push(reference: normalized, platform: parsedPlatform, auth: auth)
    }

    // MARK: - Save / Load

    /// Save images to an OCI tar archive.
    public func save(references: [String], to outputPath: String) async throws {
        var normalizedRefs: [String] = []
        for reference in references {
            normalizedRefs.append(try await resolve(reference).reference)
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try await imageStore.save(references: normalizedRefs, out: outputURL)
    }

    /// Load images from an OCI tar archive.
    public func load(from inputPath: String) async throws -> [ImageInfo] {
        let inputURL = URL(fileURLWithPath: inputPath)
        let images = try await imageStore.load(from: inputURL)
        var infos: [ImageInfo] = []
        for image in images {
            infos.append(await Self.toImageInfo(image))
        }
        return infos
    }

    // MARK: - Helpers

    /// Look an image up the way the user spelled it, falling back to the normalized
    /// `docker.io/library/...` form.
    ///
    /// Store keys are whatever string created them: `container build -t caddy:latest`
    /// stores a bare reference while a pull stores a fully-qualified one. Normalizing
    /// first therefore matched a *different* image than the one named — `rmi caddy:latest`
    /// deleted the pulled base image instead of the local build.
    private func resolve(_ reference: String) async throws -> Containerization.Image {
        if let hit = await findByName(reference) {
            return hit
        }
        if let hit = try await findByDigest(reference) {
            return hit
        }
        throw MockerError.imageNotFound(reference)
    }

    private func findByName(_ reference: String) async -> Containerization.Image? {
        for candidate in Self.resolutionCandidates(reference) {
            if let hit = try? await imageStore.get(reference: candidate) {
                return hit
            }
        }
        return nil
    }

    /// `mocker images -q` prints digests (truncated by default), and
    /// `mocker images -q | xargs mocker rmi` is the usual cleanup, so an image is also
    /// found by a prefix of its stored digest.
    private func findByDigest(_ reference: String) async throws -> Containerization.Image? {
        guard Self.looksLikeDigest(reference) else { return nil }

        let stored = (try? await imageStore.list()) ?? []
        let distinct = Self.matchingDigests(reference, in: stored.map(\.digest))
        if distinct.count > 1 {
            throw MockerError.operationFailed(
                "image reference \(reference) is ambiguous: it matches \(distinct.count) images")
        }
        guard let digest = distinct.first else { return nil }
        return stored.first(where: { $0.digest == digest })
    }

    /// The stored name to start `reference` under. `container run` knows images by name
    /// only, so an image ID (`mocker run 3f1c9a2b`, `mocker run $(mocker build -q .)`)
    /// is swapped for a name the image is stored under. Nil when `reference` is a name.
    public func runtimeReference(for reference: String) async throws -> String? {
        guard await findByName(reference) == nil else { return nil }
        return try await findByDigest(reference)?.reference
    }

    /// Whether an argument should be tried as a digest: a full `sha256:...`, the truncated
    /// form `mocker images -q` prints, or a bare hex prefix as `docker rmi` accepts.
    static func looksLikeDigest(_ reference: String) -> Bool {
        let body = digestBody(reference)
        guard body.count >= 4 else { return false }
        return body.allSatisfy(\.isHexDigit)
    }

    /// Digests matching `reference` as a prefix, deduplicated: several tags of one image
    /// share a digest and are one image, not an ambiguity. Pure, so the matching and the
    /// ambiguity rule can be tested without a store.
    static func matchingDigests(_ reference: String, in digests: [String]) -> [String] {
        // `docker rmi` takes the ID with or without the algorithm prefix, so compare hex.
        let wanted = digestBody(reference).lowercased()
        var seen: Set<String> = []
        return digests
            .filter { digestBody($0).lowercased().hasPrefix(wanted) }
            .filter { seen.insert($0).inserted }
    }

    /// The hex part of a digest, with any `sha256:` prefix removed.
    static func digestBody(_ reference: String) -> String {
        reference.hasPrefix("sha256:") ? String(reference.dropFirst("sha256:".count)) : reference
    }

    /// Store keys to try, in order: exactly what the user typed, then the same with an
    /// implied `:latest`, then the normalized registry-qualified form. Pure, so the
    /// ordering that keeps `rmi` from deleting the wrong image is directly testable.
    static func resolutionCandidates(_ reference: String) -> [String] {
        var candidates = [reference]
        if !hasTag(reference) {
            candidates.append("\(reference):latest")
        }
        for normalized in [try? normalize(reference), try? normalize(hasTag(reference) ? reference : "\(reference):latest")] {
            if let normalized, !candidates.contains(normalized) {
                candidates.append(normalized)
            }
        }
        return candidates
    }

    /// Whether a reference carries an explicit tag (a colon after the last slash,
    /// so a registry port like `localhost:5000/app` doesn't count as one).
    static func hasTag(_ reference: String) -> Bool {
        let lastComponent = reference.split(separator: "/").last.map(String.init) ?? reference
        return lastComponent.contains(":")
    }

    /// Size and creation date of an image, read from its manifest and config.
    /// Returns nils when the metadata cannot be resolved, so callers surface the gap
    /// instead of reporting a confident zero.
    static func sizeAndCreated(of image: Containerization.Image) async -> (size: UInt64?, created: Date?) {
        guard let manifest = await manifestForListing(of: image) else { return (nil, nil) }
        let total = manifestSize(manifest)
        var created: Date?
        if let content = try? await image.getContent(digest: manifest.config.digest),
           let config: ContainerizationOCI.Image = try? content.decode(),
           let stamp = config.created {
            created = RelativeDate.parse(stamp)
        }
        return (UInt64(max(0, total)), created)
    }

    /// The manifest a listing should measure: the current platform's when present,
    /// otherwise the image's sole manifest (single-arch images).
    private static func manifestForListing(
        of image: Containerization.Image
    ) async -> ContainerizationOCI.Manifest? {
        if let matched = try? await image.manifest(for: ContainerizationOCI.Platform.current) {
            return matched
        }
        guard let index = try? await image.index(),
              let sole = soleManifestDescriptor(from: index.manifests),
              let content = try? await image.getContent(digest: sole.digest) else {
            return nil
        }
        return try? content.decode()
    }

    private static func normalize(_ reference: String) throws -> String {
        // ContainerizationOCI.Reference.parse requires a fully-qualified reference with domain.
        // Docker-style short references ("alpine", "nginx:1.25", "user/image:tag") need a domain.
        var fullRef = reference
        let parts = reference.split(separator: "/", maxSplits: 1)
        if parts.count == 1 {
            // No slash → single name like "alpine:latest"
            fullRef = "docker.io/library/\(reference)"
        } else {
            let domain = String(parts[0])
            // Domain must contain a dot, colon, or be "localhost"
            let looksLikeDomain = domain.contains(".") || domain.contains(":") || domain == "localhost"
            if !looksLikeDomain {
                // e.g. "myuser/myimage:tag" — no domain, add docker.io
                fullRef = "docker.io/\(reference)"
            }
        }
        let ref = try ContainerizationOCI.Reference.parse(fullRef)
        ref.normalize()
        return ref.description
    }

    /// Repository/tag/digest only — no manifest or config reads.
    private static func basicImageInfo(_ image: Containerization.Image) -> ImageInfo {
        let name = displayName(of: image.reference)
        return ImageInfo(id: image.digest, repository: name.repository, tag: name.tag)
    }

    private static func toImageInfo(_ image: Containerization.Image) async -> ImageInfo {
        let name = displayName(of: image.reference)
        let metadata = await sizeAndCreated(of: image)

        return ImageInfo(
            id: image.digest,
            repository: name.repository,
            tag: name.tag,
            size: metadata.size,
            created: metadata.created
        )
    }

    /// Repository and tag to show for a stored reference; `<none>` for a dangling image.
    static func displayName(of reference: String) -> (repository: String, tag: String) {
        if isDanglingReference(reference) {
            return ("<none>", "<none>")
        }
        let ref = try? ImageReference.parse(reference)
        return (ref?.fullRepository ?? reference, ref?.tag ?? "latest")
    }
}
