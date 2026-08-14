import Foundation
import Logging
import Containerization
import ContainerizationOCI
import ContainerizationExtras

/// Manages OCI images using Apple's Containerization API
/// Provides translation layer between Docker API and Containerization image operations
/// Thread-safe via Swift actor isolation
public actor ImageManager {
    private let logger: Logger
    private let imageStore: ImageStore
    private let defaultPlatform: Platform
    private var eventEmitter: EventEmitter?

    public init(logger: Logger, imageStorePath: URL? = nil) throws {
        self.logger = logger

        // Initialize ImageStore with default or custom path
        if let path = imageStorePath {
            self.imageStore = try ImageStore(path: path)
        } else {
            self.imageStore = ImageStore.default
        }

        // Use the current platform
        self.defaultPlatform = Platform.current
    }

    /// Root of the `ImageStore` this manager loads into.
    ///
    /// Exists so that a caller which has to reason about a file *inside* the
    /// store -- `initfs.ext4`, which Containerization builds at the store's own
    /// path -- can ask the manager instead of re-deriving that path from the
    /// same defaults and trusting the two to stay equal.
    ///
    /// `nonisolated` because it is fixed at construction: making callers await
    /// a constant would be the reason they went on hand-deriving it.
    nonisolated public var storeRoot: URL { imageStore.path }

    /// Initialize the image manager
    public func initialize() async throws {
        logger.info("Initializing ImageManager", metadata: [
            "store_path": "\(imageStore.path.path)"
        ])

        // ImageStore is already initialized in init()
        logger.info("ImageManager initialized")
    }

    /// Set the EventEmitter for emitting Docker events
    public func setEventEmitter(_ emitter: EventEmitter) {
        self.eventEmitter = emitter
    }

    /// Load images from an OCI Image Layout directory into the ImageStore
    public func loadFromOCILayout(directory: URL) async throws -> [Containerization.Image] {
        logger.info("Loading images from OCI layout", metadata: [
            "directory": "\(directory.path)"
        ])

        let loadedImages = try await imageStore.load(from: directory)

        logger.info("Successfully loaded images from OCI layout", metadata: [
            "count": "\(loadedImages.count)",
            "images": "\(loadedImages.map { $0.reference }.joined(separator: ", "))"
        ])

        return loadedImages
    }

    /// Load images from a tar archive (OCI or Docker format)
    /// - Parameter tarData: The tar archive data
    /// - Returns: Array of loaded images
    public func loadImageFromTar(_ tarData: Data) async throws -> [Containerization.Image] {
        logger.info("Loading images from tar archive", metadata: [
            "size_bytes": "\(tarData.count)"
        ])

        // Create temp directory for extraction
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-image-load-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            logger.debug("Created temp directory", metadata: ["path": "\(tempDir.path)"])

            // Write tar data to temp file
            let tarPath = tempDir.appendingPathComponent("image.tar")
            try tarData.write(to: tarPath)
            logger.debug("Wrote tar archive", metadata: ["path": "\(tarPath.path)"])

            // Extract tar archive
            let extractDir = tempDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", tarPath.path, "-C", extractDir.path]

            let pipe = Pipe()
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                logger.error("Failed to extract tar", metadata: ["error": "\(errorMsg)"])
                throw ImageManagerError.tarExtractionFailed(errorMsg)
            }

            logger.debug("Extracted tar archive", metadata: ["path": "\(extractDir.path)"])

            // Load from OCI layout
            let loadedImages = try await loadFromOCILayout(directory: extractDir)

            // Clean up temp directory
            try? FileManager.default.removeItem(at: tempDir)
            logger.debug("Cleaned up temp directory")

            return loadedImages
        } catch {
            // Clean up temp directory on error
            try? FileManager.default.removeItem(at: tempDir)
            logger.error("Failed to load image from tar", metadata: ["error": "\(error)"])
            throw error
        }
    }

    // MARK: - Image Listing

    /// List all images
    public func listImages(filters: [String: [String]] = [:]) async throws -> [ImageSummary] {
        logger.debug("Listing images", metadata: [
            "filters": "\(filters)"
        ])

        let images = try await imageStore.list()

        var summaries: [ImageSummary] = []
        for image in images {
            do {
                // Try to get manifest and config for the current platform
                // Note: For images pulled with a platform filter, only that platform's content is available
                let manifest = try await image.manifest(for: defaultPlatform)
                let config = try await image.config(for: defaultPlatform)

                // Generate Docker-compatible ID from digest
                let dockerID = generateDockerID(from: image.digest)

                // Calculate sizes - sum of all layer sizes (the actual image data)
                // NOTE: These are COMPRESSED sizes (tar.gz blobs) from OCI manifest.layers[].size
                // Docker reports UNCOMPRESSED sizes, so our values will be smaller (~3x for gzip)
                // Example: alpine shows 4.14MB here vs 13.3MB in Docker
                // See Documentation/LIMITATIONS.md - "Image Size Reporting" section
                // TODO: Track uncompressed sizes during pull (see IMPLEMENTATION_PLAN.md Phase 4)
                let size = manifest.layers.reduce(Int64(0)) { $0 + Int64($1.size) }
                let virtualSize = size

                // Parse created timestamp from ISO 8601 string
                let created = parseCreatedTimestamp(config.created)

                let summary = ImageSummary(
                    id: dockerID,
                    repoTags: [image.reference],
                    repoDigests: [image.digest],
                    created: created,
                    size: size,
                    virtualSize: virtualSize,
                    labels: config.config?.labels ?? [:]
                )

                summaries.append(summary)
            } catch {
                logger.warning("Failed to process image", metadata: [
                    "reference": "\(image.reference)",
                    "error": "\(error)"
                ])
                continue
            }
        }

        logger.info("Listed images", metadata: ["count": "\(summaries.count)"])
        return summaries
    }

    // MARK: - Image Inspection

    /// Get detailed information about an image
    public func inspectImage(nameOrId: String) async throws -> ImageDetails? {
        logger.debug("Inspecting image", metadata: ["name_or_id": "\(nameOrId)"])

        // Resolve image by name or ID
        guard let image = try? await resolveImage(nameOrId: nameOrId) else {
            logger.warning("Image not found", metadata: ["name_or_id": "\(nameOrId)"])
            return nil
        }

        // Get manifest and config for default platform
        let manifest = try await image.manifest(for: defaultPlatform)
        let config = try await image.config(for: defaultPlatform)

        let dockerID = generateDockerID(from: image.digest)

        // Calculate sizes - sum of all layer sizes (the actual image data)
        let size = manifest.layers.reduce(Int64(0)) { $0 + Int64($1.size) }
        let virtualSize = size

        // Build layer list
        let layers = manifest.layers.map { $0.digest }

        // Extract parent and comment from history (if available)
        let parent = ""  // OCI doesn't have parent field
        let comment = config.history?.first?.comment ?? ""

        // Parse created date from ISO 8601 string
        let createdDate = parseCreatedDate(config.created) ?? Date()

        let details = ImageDetails(
            id: dockerID,
            repoTags: [image.reference],
            repoDigests: [image.digest],
            parent: parent,
            comment: comment,
            created: createdDate,
            container: "",
            containerConfig: mapToImageContainerConfig(config.config),
            dockerVersion: "",
            author: config.author ?? "",
            config: mapToImageContainerConfig(config.config),
            architecture: config.architecture,
            os: config.os,
            size: size,
            virtualSize: virtualSize,
            graphDriver: GraphDriver(name: "overlay2"),
            rootFS: RootFS(type: "layers", layers: layers),
            metadata: ImageMetadata()
        )

        logger.info("Image inspected", metadata: ["name_or_id": "\(nameOrId)"])
        return details
    }

    // MARK: - Image Pulling

    /// Resolve the manifest for an image and extract layer digests and manifest digest
    /// This allows us to get real layer IDs and the manifest digest before pulling
    public func resolveManifestLayersWithDigest(
        reference: String,
        auth: RegistryAuthentication? = nil
    ) async throws -> (layerDigests: [String], layerSizes: [Int64], manifestDigest: String) {
        logger.debug("Resolving manifest layers", metadata: ["reference": "\(reference)"])

        // Normalize image reference
        let normalizedRef = normalizeImageReference(reference)

        // Create authentication if provided
        var authentication: Authentication?
        if let auth = auth, let username = auth.username, let password = auth.password {
            authentication = BasicAuthentication(username: username, password: password)
        }

        // Create registry client
        let client = try RegistryClient(reference: normalizedRef, insecure: false, auth: authentication)

        // Parse reference to get name and tag
        let ref = try Reference.parse(normalizedRef)
        let name = ref.path
        guard let tag = ref.tag ?? ref.digest else {
            throw ImageManagerError.invalidReference("Invalid tag/digest for image reference \(normalizedRef)")
        }

        // Resolve root descriptor (manifest)
        let rootDescriptor = try await client.resolve(name: name, tag: tag)

        // Fetch the manifest and track the manifest digest
        let manifest: Manifest
        let manifestDigest: String

        switch rootDescriptor.mediaType {
        case MediaTypes.imageManifest, MediaTypes.dockerManifest:
            // Direct manifest
            manifest = try await client.fetch(name: name, descriptor: rootDescriptor)
            manifestDigest = rootDescriptor.digest
        case MediaTypes.index, MediaTypes.dockerManifestList:
            // Manifest list - need to select platform-specific manifest
            let index: Index = try await client.fetch(name: name, descriptor: rootDescriptor)

            // Find manifest for our platform
            guard let platformManifest = index.manifests.first(where: { manifestDesc in
                guard let platform = manifestDesc.platform else { return false }
                // Check if platform matches (os and architecture)
                return platform.os == self.defaultPlatform.os &&
                       platform.architecture == self.defaultPlatform.architecture
            }) else {
                throw ImageManagerError.platformNotFound("No manifest found for platform \(self.defaultPlatform)")
            }

            // Fetch the platform-specific manifest
            manifest = try await client.fetch(name: name, descriptor: platformManifest)
            manifestDigest = platformManifest.digest
        default:
            throw ImageManagerError.unsupportedMediaType("Unsupported media type: \(rootDescriptor.mediaType)")
        }

        // Extract layer digests and sizes (in the order they appear in the manifest)
        let layerDigests = manifest.layers.map { $0.digest }
        let layerSizes = manifest.layers.map { Int64($0.size) }

        logger.debug("Resolved manifest layers", metadata: [
            "count": "\(layerDigests.count)",
            "manifest_digest": "\(manifestDigest.prefix(19))...",
            "digests": "\(layerDigests.prefix(3).joined(separator: ", "))...",
            "total_layer_size": "\(layerSizes.reduce(0, +))"
        ])

        return (layerDigests, layerSizes, manifestDigest)
    }

    /// Pull an image from a registry
    public func pullImage(
        reference: String,
        auth: RegistryAuthentication? = nil,
        progress: ContainerizationExtras.ProgressHandler? = nil
    ) async throws -> ImageDetails {
        logger.info("Pulling image", metadata: ["reference": "\(reference)"])

        // Normalize image reference (add :latest if needed, add docker.io registry)
        let normalizedRef = normalizeImageReference(reference)
        logger.debug("Normalized reference for pull", metadata: [
            "original": "\(reference)",
            "normalized": "\(normalizedRef)"
        ])

        // Create authentication if provided
        var authentication: Authentication?
        if let auth = auth, let username = auth.username, let password = auth.password {
            authentication = BasicAuthentication(username: username, password: password)
        }

        // Pull image using ImageStore with normalized reference
        let image = try await imageStore.pull(
            reference: normalizedRef,
            platform: defaultPlatform,
            insecure: false,
            auth: authentication,
            progress: progress
        )

        // Get image details
        let manifest = try await image.manifest(for: defaultPlatform)
        let config = try await image.config(for: defaultPlatform)

        let dockerID = generateDockerID(from: image.digest)

        // Calculate sizes - sum of all layer sizes (the actual image data)
        let size = manifest.layers.reduce(Int64(0)) { $0 + Int64($1.size) }
        let virtualSize = size

        // Build layer list
        let layers = manifest.layers.map { $0.digest }

        // Extract parent and comment from history (if available)
        let parent = ""  // OCI doesn't have parent field
        let comment = config.history?.first?.comment ?? ""

        // Parse created date from ISO 8601 string
        let createdDate = parseCreatedDate(config.created) ?? Date()

        let details = ImageDetails(
            id: dockerID,
            repoTags: [reference],
            repoDigests: [image.digest],
            parent: parent,
            comment: comment,
            created: createdDate,
            container: "",
            containerConfig: mapToImageContainerConfig(config.config),
            dockerVersion: "",
            author: config.author ?? "",
            config: mapToImageContainerConfig(config.config),
            architecture: config.architecture,
            os: config.os,
            size: size,
            virtualSize: virtualSize,
            graphDriver: GraphDriver(name: "overlay2"),
            rootFS: RootFS(type: "layers", layers: layers),
            metadata: ImageMetadata()
        )

        logger.info("Image pulled successfully", metadata: [
            "reference": "\(reference)",
            "digest": "\(image.digest)"
        ])

        // Emit image pull event
        if let eventEmitter = eventEmitter {
            var attributes: [String: String] = [
                "name": reference
            ]
            await eventEmitter.emitImageEvent(
                action: "pull",
                imageID: dockerID,
                attributes: attributes
            )
        }

        return details
    }

    // MARK: - Image Deletion

    /// Delete an image
    public func deleteImage(nameOrId: String, force: Bool = false) async throws -> [ImageDeleteItem] {
        logger.info("Deleting image", metadata: [
            "name_or_id": "\(nameOrId)",
            "force": "\(force)"
        ])

        // Resolve image by name or ID
        let image = try await resolveImage(nameOrId: nameOrId)

        let imageDigest = image.digest
        let dockerID = generateDockerID(from: imageDigest)
        let imageReference = image.reference

        logger.debug("Image resolved for deletion", metadata: [
            "reference": "\(imageReference)",
            "digest": "\(imageDigest)",
            "docker_id": "\(dockerID)"
        ])

        // Check if image is in use by containers (if not force)
        if !force {
            // TODO: Check with ContainerManager if image is in use

            // **A digest reference must not delete a row it did not name.**
            // This method deletes by the RESOLVED row's reference below, not by
            // the string it was given, and `resolveImage` now resolves
            // `repo@sha256:<hex>` by content. Without this guard,
            // `docker rmi alpha@sha256:<digest>` against a store whose only row
            // is `alpha:latest` untags `alpha:latest` and cleans up the content
            // behind it -- removing a name the caller never typed. MEASURED in
            // Task 11's review, before this guard existed:
            // `deleteImage(alpha@digest)` returned
            // `untagged: alpha:latest, deleted: sha256:f056fb09b4cd…`, and
            // `alpha:latest` was gone afterwards. Before the resolver arm the
            // same call threw `No such image`, so the widening turned an error
            // into a destructive success.
            //
            // Docker's own behaviour is the model, and it is NOT "the digest
            // form just works": `rmi` by digest removes the digest reference,
            // and refuses to remove content carrying other references without
            // `--force`. So a digest reference naming an actual stored row still
            // deletes exactly that row -- the equality below holds for it -- and
            // one that resolves to a differently-named row is refused, with the
            // message saying what to do instead.
            if let requested = ImageIdentity.exactDigest(of: nameOrId),
               imageReference != nameOrId {
                logger.warning("Refusing to delete a row the digest reference did not name", metadata: [
                    "requested": "\(nameOrId)",
                    "resolved": "\(imageReference)"
                ])
                throw ImageManagerError.deleteFailed(
                    "\(nameOrId) resolves to \(imageReference), which is a different reference; "
                        + "deleting it would remove a name that was not asked for. Delete "
                        + "\(imageReference) by name, or repeat with force to remove the content "
                        + "held under \(requested.repository)."
                )
            }
        }

        // Delete the image by reference
        try await imageStore.delete(reference: imageReference, performCleanup: true)

        logger.info("Image deleted", metadata: [
            "name_or_id": "\(nameOrId)",
            "digest": "\(imageDigest)"
        ])

        // Emit image delete event
        if let eventEmitter = eventEmitter {
            var attributes: [String: String] = [
                "name": imageReference
            ]
            await eventEmitter.emitImageEvent(
                action: "delete",
                imageID: dockerID,
                attributes: attributes
            )
        }

        return [
            ImageDeleteItem(untagged: imageReference),
            ImageDeleteItem(deleted: dockerID)
        ]
    }

    // MARK: - Image Tagging

    /// Tag an image
    public func tagImage(source: String, target: String) async throws {
        logger.info("Tagging image", metadata: [
            "source": "\(source)",
            "target": "\(target)"
        ])

        _ = try await imageStore.tag(existing: source, new: target)

        logger.info("Image tagged", metadata: [
            "source": "\(source)",
            "target": "\(target)"
        ])

        // Emit image tag event
        if let eventEmitter = eventEmitter {
            // For tag events, we need to resolve the image to get its ID
            if let image = try? await resolveImage(nameOrId: source) {
                let dockerID = generateDockerID(from: image.digest)
                var attributes: [String: String] = [
                    "name": target
                ]
                await eventEmitter.emitImageEvent(
                    action: "tag",
                    imageID: dockerID,
                    attributes: attributes
                )
            }
        }
    }

    // MARK: - Helper Methods

    /// Resolve image by name or ID
    /// Handles multiple input formats:
    /// - Full reference: docker.io/library/nginx:alpine
    /// - Short reference: nginx:alpine, nginx
    /// - Short ID: 4986bf8c1536 (12 chars)
    /// - Long ID: sha256:4986bf8c15... (full digest)
    /// - Exact digest reference: nginx@sha256:4986bf8c15... (repository AND digest)
    ///
    /// **The exact-digest arm was added because nothing here could resolve the
    /// only form the sandbox engine is able to use.**
    /// `ContainerManager.createContainer` resolves an image with the same string
    /// it records as `ContainerInfo.image` (`:1698` and `:1901`),
    /// `startContainer` resolves that recorded string again when it rebuilds a
    /// container from persisted state (`:2218`), and the engine's `Inspect`
    /// requires the recorded string to be an exact digest reference or it
    /// answers `invalid_output`. One field, three constraints, and only
    /// `repository@sha256:<hex>` satisfies all three -- which is also exactly
    /// what Gas Can sends for every create
    /// (`crates/gascan-core/src/runtime.rs:677-686`).
    ///
    /// Before this arm existed, such a string fell through to `matchesReference`
    /// below, which compares names and cannot match a digest, so every create
    /// following a successful `PrepareImage` failed to resolve its own image.
    ///
    /// **The change is additive, and after the ordering fix below it is additive
    /// by construction rather than by measurement.** An exact digest reference is
    /// neither `isShortID` -- the `@`, the `:` and the repository letters fail
    /// `^[a-f0-9]{12,64}$` -- nor `isLongID`, whose `hasPrefix("sha256:")` fails
    /// on the repository prefix. So `matchesReference` still runs for it, and it
    /// runs *first*: every name arm is tried against every row before the digest
    /// arm is tried at all. A store row whose reference literally is
    /// `repository@sha256:<hex>` therefore still resolves by exact string match,
    /// and no store can be built in which this arm takes a resolution away from
    /// an arm that existed before it. Nothing that resolved before resolves
    /// differently; a form that threw can now succeed.
    ///
    /// This does change Arca's Docker surface: `docker run|rmi|inspect
    /// repo@sha256:...` now works where it previously reported "No such image".
    /// That is Docker's own semantics for the form, and the change is deliberate
    /// rather than a side effect.
    private func resolveImage(nameOrId: String) async throws -> Containerization.Image {
        // Check if input is a Docker ID (short or long)
        let isShortID = nameOrId.range(of: "^[a-f0-9]{12,64}$", options: .regularExpression) != nil
        let isLongID = nameOrId.hasPrefix("sha256:")
        let exactDigest = ImageIdentity.exactDigest(of: nameOrId)

        logger.debug("Resolving image", metadata: [
            "name_or_id": "\(nameOrId)",
            "is_short_id": "\(isShortID)",
            "is_long_id": "\(isLongID)",
            "is_exact_digest": "\(exactDigest != nil)"
        ])

        // For both ID-based and tag-based lookups, we need to list all images
        // because the stored reference might not match our normalized version
        let images = try await imageStore.list()

        // **One pass per arm, not one pass per row, and the difference is
        // correctness rather than style.** `imageStore.list()` order is the
        // store's own and is neither insertion nor sorted order -- MEASURED in
        // Task 11's re-review, which saw `getImage` and `deleteImage` resolve the
        // same string to different rows inside one process, and a legitimate
        // `docker rmi repo@sha256:x` throw on 2 of 5 runs.
        //
        // The cause was arm precedence being decided by row order: with the arms
        // interleaved inside one loop, whichever ROW came first decided which
        // ARM answered. Two rows can both match one input -- a row literally
        // named `repo@sha256:x` matches by name, and the row holding that
        // content matches by digest -- so the answer depended on the store's
        // enumeration.
        //
        // Ordering the arms fixes it at the root and buys three things: the
        // result is a function of the store's contents rather than its order;
        // NAME matching always beats CONTENT matching, so the exact-digest arm
        // can never take a resolution away from an arm that existed before it --
        // the additive claim now holds by construction rather than by having
        // failed to find a counterexample; and `deleteImage` can trust that a
        // digest reference naming a real row resolves to THAT row, which is what
        // makes its guard deterministic.
        //
        // **Every arm collects, sorts and takes the first**, including the two ID
        // arms, and that uniformity is load-bearing rather than tidy. A first
        // version of this fix ordered the arms but left the ID arms returning
        // whichever row the loop reached first -- and both can match more than
        // one row, because two references to one content share a digest. Task
        // 11's re-review measured five reads of one unchanged store, inside one
        // process, giving two different answers for a short ID and for a long
        // ID, on the supposedly-fixed build. Half a fix here is a boundary the
        // next reader has to know about, and the comment explaining it is what
        // they would have to find first.
        //
        // NOT fixed here, and pre-existing: `deleteImage` deletes by the
        // resolved row's reference and its digest-reference guard cannot fire
        // for an ID input, so `docker rmi <short-id>` over content carrying two
        // names still untags one of them -- now deterministically rather than
        // arbitrarily. Docker refuses that outright ("image is referenced in
        // multiple repositories"). Reported rather than fixed: it is not this
        // change's to make.

        // Match short ID (first 12+ chars)
        if isShortID,
           let image = firstByReference(images.filter {
               generateDockerID(from: $0.digest)
                   .replacingOccurrences(of: "sha256:", with: "").hasPrefix(nameOrId)
           }) {
            logger.debug("Matched image by short ID", metadata: [
                "input": "\(nameOrId)",
                "reference": "\(image.reference)",
                "digest": "\(image.digest)"
            ])
            return image
        }

        // Match long ID (full digest)
        if isLongID,
           let image = firstByReference(images.filter {
               generateDockerID(from: $0.digest) == nameOrId
           }) {
            logger.debug("Matched image by long ID", metadata: [
                "input": "\(nameOrId)",
                "reference": "\(image.reference)",
                "digest": "\(image.digest)"
            ])
            return image
        }

        // Match by reference (tag) - need to check multiple variations.
        // Ahead of the digest arm below: a row the caller NAMED is a more
        // specific answer than a row that merely holds the content.
        if !isShortID, !isLongID,
           let image = firstByReference(images.filter {
               matchesReference(stored: $0.reference, input: nameOrId)
           }) {
            logger.debug("Matched image by reference", metadata: [
                "input": "\(nameOrId)",
                "reference": "\(image.reference)",
                "digest": "\(image.digest)"
            ])
            return image
        }

        // Match an exact digest reference: both halves, never one.
        //
        // The repository is compared as well as the digest, and it is compared
        // exactly -- no registry normalization -- which is the same direction the
        // engine's PrepareImage chose. Matching on the digest alone would resolve
        // `anything-at-all@sha256:<hex>` to this image, which is a container
        // created from content under a name its caller never asked for. A false
        // "not found" is visible and recoverable; a false match is neither.
        //
        // Both sides go through ImageIdentity.repository(of:), the one split, so
        // that the stored `workspace:latest` and the requested
        // `workspace@sha256:...` meet on `workspace` by the same rule the engine
        // uses when it decides it holds the content at all.
        if let exactDigest,
           let image = firstByReference(images.filter {
               $0.digest == exactDigest.digest
                   && ImageIdentity.repository(of: $0.reference) == exactDigest.repository
           }) {
            logger.debug("Matched image by exact digest reference", metadata: [
                "input": "\(nameOrId)",
                "reference": "\(image.reference)",
                "digest": "\(image.digest)"
            ])
            return image
        }

        // Not found
        logger.warning("Image not found", metadata: ["name_or_id": "\(nameOrId)"])
        throw ImageManagerError.imageNotFound(nameOrId)
    }

    /// The one candidate a set of equally-valid matches resolves to.
    ///
    /// Every arm of `resolveImage` funnels through this, so "which row wins" is
    /// decided in one place by one rule rather than four times by
    /// `imageStore.list()`'s enumeration. The reference is the tie-break because
    /// it is the only field that distinguishes two rows on one content: they
    /// share a digest by construction, which is precisely why the ambiguity
    /// exists.
    ///
    /// Ascending, and the direction is arbitrary but must be *fixed*. A test
    /// pins it (`ImageResolutionTests` requires the `:alpha` row over the
    /// `:zulu` one), because a tie-break nothing asserts is a tie-break a later
    /// edit can reverse or delete without anything noticing -- which is exactly
    /// what happened to the first version of this: both mutations survived the
    /// whole suite.
    private func firstByReference(
        _ candidates: [Containerization.Image]
    ) -> Containerization.Image? {
        candidates.min { $0.reference < $1.reference }
    }

    /// Check if a stored image reference matches an input reference
    /// Handles Docker reference formats with proper normalization:
    /// - Exact match: stored=nginx:alpine, input=nginx:alpine
    /// - Without tag: stored=nginx:latest, input=nginx
    /// - Without registry: stored=docker.io/library/nginx:alpine, input=nginx:alpine
    /// - User repos: stored=docker.io/apache/superset:tag, input=apache/superset:tag
    ///
    /// Docker reference format: [registry/][namespace/]repository[:tag|@digest]
    /// - nginx → docker.io/library/nginx:latest
    /// - nginx:alpine → docker.io/library/nginx:alpine
    /// - apache/superset:tag → docker.io/apache/superset:tag
    /// - myregistry.com/repo:tag → myregistry.com/repo:tag
    private func matchesReference(stored: String, input: String) -> Bool {
        // Exact match
        if stored == input {
            return true
        }

        // Normalize the input reference using the same logic as when images are stored
        let normalizedInput = normalizeImageReference(input)

        // Match normalized input against stored reference
        if stored == normalizedInput {
            return true
        }

        // Also try suffix matching for cases where stored might have different normalization
        // e.g., stored=docker.io/library/nginx:alpine, input normalized to same
        // This handles edge cases in normalization
        let storedComponents = stored.components(separatedBy: "/")
        let inputComponents = normalizedInput.components(separatedBy: "/")

        // If input has fewer components after normalization, try suffix matching
        if inputComponents.count < storedComponents.count {
            let storedSuffix = storedComponents.suffix(inputComponents.count).joined(separator: "/")
            if storedSuffix == normalizedInput {
                return true
            }
        }

        return false
    }

    /// Generate Docker-compatible image ID from OCI digest
    private func generateDockerID(from digest: String) -> String {
        // Docker IDs are sha256: followed by 64 hex chars
        if digest.hasPrefix("sha256:") {
            return digest
        }
        return "sha256:\(digest)"
    }

    /// Check if an image exists
    public func imageExists(nameOrId: String) async -> Bool {
        do {
            let image = try await inspectImage(nameOrId: nameOrId)
            return image != nil
        } catch {
            return false
        }
    }

    /// Get the Image object for use with Containerization API
    public func getImage(nameOrId: String) async throws -> Containerization.Image {
        logger.debug("Getting image", metadata: ["name_or_id": "\(nameOrId)"])

        // Resolve image by name or ID
        let image = try await resolveImage(nameOrId: nameOrId)

        logger.debug("Image retrieved", metadata: [
            "reference": "\(image.reference)",
            "digest": "\(image.digest)"
        ])

        return image
    }

    /// Whether this store holds, in full, the content named by an exact digest.
    ///
    /// **The lookup is exact string equality against the digest each stored
    /// image carries, and deliberately not `resolveImage(nameOrId:)`.** That
    /// resolver has three arms, and two of them are wrong for a caller asking
    /// "do you hold this content": the reference arm matches a *tag*
    /// (`matchesReference` above, which also normalizes registries and falls
    /// back to suffix matching), so it answers about a name that can be
    /// remapped to different bytes at any time; and the short-ID arm matches a
    /// 12-character prefix. A caller building a promise on the answer needs
    /// neither. Passing `sha256:<hex>` to `resolveImage` would take its long-ID
    /// arm, which is exact -- but only by coincidence of the input, and a later
    /// caller passing something else would silently get the forgiving arms.
    ///
    /// The digest compared against is the store's own root descriptor digest,
    /// which for an image imported from a single-manifest OCI layout is an
    /// index Containerization *synthesizes* during the import
    /// (`ImageStore+Import.swift:216-224`), not the manifest digest the layout
    /// named. A caller holding the manifest digest for such an image gets
    /// `.noImageForDigest` here. That is the safe direction -- a false "not
    /// held" is recoverable and visible, a false "held" is neither -- but it is
    /// a real limitation and not an accident.
    ///
    /// Three cases and not a `Bool`, for the reason `imageExists(nameOrId:)`
    /// above is too cheap an answer to build a promise on: it collapses "no
    /// such image", "the store has a row and cannot produce its bytes", and
    /// "the read itself failed" into `false`. Those demand different reports.
    ///
    /// **Every row carrying the digest is reported, not the first one found.**
    /// A store holds one row per *reference*, and `tagImage(source:target:)`
    /// above adds a second reference to content that is already there, so two
    /// rows can carry one digest. An earlier revision of this returned the
    /// first match, and a caller that then tested that one reference against
    /// the name it asked about got a `not_found` decided by `imageStore.list()`
    /// ordering -- for content the store demonstrably held, naming the wrong
    /// reference while it did so. The blob walk below is unaffected by that
    /// multiplicity and is done once: the rows share a root descriptor and a
    /// content store, so they reference identical blobs by construction.
    ///
    /// - Parameter digest: The content digest, in the `sha256:<hex>` form the
    ///   store records. Anything else matches nothing.
    /// - Throws: Whatever listing the store throws. A store that cannot be read
    ///   is not a store that holds nothing.
    package func heldImageContent(digest: String) async throws -> HeldImageContent {
        let images = try await imageStore.list()
        let matches = images.filter { $0.digest == digest }
        guard let image = matches.first else {
            logger.debug("No image holds this content digest", metadata: ["digest": "\(digest)"])
            return .noImageForDigest
        }
        // Sorted for the reason the missing digests below are: `list()`'s order
        // is the store's, and a caller putting these in a message would
        // otherwise report one store two different ways across two runs.
        let references = matches.map(\.reference).sorted()

        // `referencedDigests()` reads the image's own index blob before it can
        // name anything else, so a throw here is that blob being absent or
        // undecodable -- which is this image's content missing, reported as
        // such rather than as a read failure.
        let referenced: [String]
        do {
            referenced = try await image.referencedDigests()
        } catch {
            logger.warning("Image index unreadable", metadata: [
                "references": "\(references.joined(separator: ", "))",
                "digest": "\(digest)",
                "error": "\(error)"
            ])
            return .blobsMissing(references: references, digests: [image.digest])
        }

        // Every blob the image names, fetched from the content store. This is
        // what separates a store that has a row from a store a container can
        // actually be created from: `OverlayFSUnpacker.unpack` reads each layer
        // by digest, and a layer that is not here fails there instead.
        //
        // A throw from `getContent` is the blob being absent: its other failure
        // mode is a digest the image does not reference, and every digest here
        // came from the image's own reference walk.
        //
        // Not exhaustive in one case, deliberately unrepaired: `referencedDigests`
        // skips the children of a manifest it cannot decode. The manifest's own
        // digest is still in the list, so such an image is still reported
        // incomplete -- just without its layers enumerated beneath it.
        var missing: [String] = []
        for candidate in referenced {
            do {
                _ = try await image.getContent(digest: candidate)
            } catch {
                missing.append(generateDockerID(from: candidate))
            }
        }
        guard missing.isEmpty else {
            logger.warning("Image is missing content it references", metadata: [
                "references": "\(references.joined(separator: ", "))",
                "digest": "\(digest)",
                "missing": "\(missing.joined(separator: ", "))"
            ])
            // Sorted because the walk's order follows the index, and a caller
            // that puts these in a message would otherwise report the same
            // damaged image two different ways.
            return .blobsMissing(references: references, digests: missing.sorted())
        }

        logger.debug("Image content held in full", metadata: [
            "references": "\(references.joined(separator: ", "))",
            "digest": "\(digest)"
        ])
        return .held(references: references)
    }

    /// Normalize image reference to Docker Hub format
    /// Docker convention:
    /// - "alpine" → "docker.io/library/alpine:latest"
    /// - "alpine:3.18" → "docker.io/library/alpine:3.18"
    /// - "myuser/image" → "docker.io/myuser/image:latest"
    /// - "registry.com/image" → "registry.com/image:latest" (already has registry)
    private func normalizeImageReference(_ reference: String) -> String {
        var normalized = reference

        // Add :latest tag if no tag or digest is specified
        if !normalized.contains(":") && !normalized.contains("@") {
            normalized = "\(normalized):latest"
        }

        // Add docker.io registry prefix if no registry is specified
        // Check if reference already has a registry (contains '.' before first '/')
        let hasRegistry = normalized.split(separator: "/").first?.contains(".") ?? false
        if !hasRegistry {
            // Check if it's a single-component name (e.g., "alpine:latest")
            let components = normalized.split(separator: "/")
            if components.count == 1 {
                // Official image: alpine → docker.io/library/alpine
                normalized = "docker.io/library/\(normalized)"
            } else {
                // User image: user/image → docker.io/user/image
                normalized = "docker.io/\(normalized)"
            }
        }

        return normalized
    }

    /// Parse ISO 8601 timestamp string to Unix timestamp
    private func parseCreatedTimestamp(_ isoString: String?) -> Int64 {
        guard let isoString = isoString else { return 0 }

        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else {
            return 0
        }

        return Int64(date.timeIntervalSince1970)
    }

    /// Parse ISO 8601 timestamp string to Date
    private func parseCreatedDate(_ isoString: String?) -> Date? {
        guard let isoString = isoString else { return nil }

        let formatter = ISO8601DateFormatter()
        return formatter.date(from: isoString)
    }

    /// Map OCI ImageConfig to ImageContainerConfig
    private func mapToImageContainerConfig(_ config: ContainerizationOCI.ImageConfig?) -> ImageContainerConfig? {
        guard let config = config else { return nil }

        return ImageContainerConfig(
            hostname: "",
            domainname: "",
            user: config.user ?? "",
            attachStdin: false,
            attachStdout: false,
            attachStderr: false,
            exposedPorts: nil,
            tty: false,
            openStdin: false,
            stdinOnce: false,
            env: config.env ?? [],
            cmd: config.cmd ?? [],
            image: nil,
            volumes: nil,
            workingDir: config.workingDir ?? "",
            entrypoint: config.entrypoint,
            onBuild: nil,
            labels: config.labels ?? [:]
        )
    }
}

// MARK: - Held content

/// What an image store can say about content named by an exact digest.
///
/// The answer to `heldImageContent(digest:)`. Three cases rather than a `Bool`
/// because they demand different reports from a caller: content that never
/// arrived has to be sent, content whose blobs are gone has to be sent again,
/// and content that is here in full needs nothing. `Equatable` so a test can
/// state the whole answer rather than one field of it.
///
/// Both content-bearing cases carry `references` as a sorted list and not a
/// single name, because a store holds one row per reference and a tag adds a
/// row to content that is already there. A caller deciding anything about the
/// *name* the content arrived under has to see all of them or it decides on
/// whichever row the store happened to list first.
package enum HeldImageContent: Sendable, Equatable {
    /// The store holds this digest under every reference listed, and every blob
    /// those rows name is present.
    case held(references: [String])

    /// No image in this store carries this digest.
    case noImageForDigest

    /// The digest is in the store under these references, but the content store
    /// cannot produce these blobs, in `sha256:<hex>` form. Nothing can be
    /// created from the image until they arrive.
    case blobsMissing(references: [String], digests: [String])
}

// MARK: - Errors

public enum ImageManagerError: Error, CustomStringConvertible {
    case notInitialized
    case notImplemented
    case imageNotFound(String)
    case pullFailed(String)
    case deleteFailed(String)
    case tagFailed(String)
    case invalidReference(String)
    case platformNotFound(String)
    case unsupportedMediaType(String)
    case tarExtractionFailed(String)

    public var description: String {
        switch self {
        case .notInitialized:
            return "ImageManager not initialized"
        case .notImplemented:
            return "Feature not yet implemented (Containerization API integration in progress)"
        case .imageNotFound(let ref):
            return "No such image: \(ref)"
        case .pullFailed(let msg):
            return "Failed to pull image: \(msg)"
        case .deleteFailed(let msg):
            return "Failed to delete image: \(msg)"
        case .tagFailed(let msg):
            return "Failed to tag image: \(msg)"
        case .invalidReference(let ref):
            return "Invalid image reference: \(ref)"
        case .platformNotFound(let msg):
            return "Platform not found: \(msg)"
        case .unsupportedMediaType(let msg):
            return "Unsupported media type: \(msg)"
        case .tarExtractionFailed(let msg):
            return "Failed to extract tar archive: \(msg)"
        }
    }
}
