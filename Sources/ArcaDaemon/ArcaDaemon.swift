import Foundation
import Logging
import NIOHTTP1
import DockerAPI
import ContainerBridge
import Containerization

/// The main Arca daemon that implements the Docker Engine API server
public final class ArcaDaemon: @unchecked Sendable {
    private let socketPath: String
    private let kernelPath: String?
    private let logger: Logger
    private var server: ArcaServer?
    private var containerManager: ContainerBridge.ContainerManager?
    private var imageManager: ImageManager?
    private var execManager: ExecManager?
    private var networkManager: NetworkManager?
    private var volumeManager: VolumeManager?
    private var eventManager: EventManager?

    public init(socketPath: String, kernelPath: String? = nil, logger: Logger) {
        self.socketPath = socketPath
        self.kernelPath = kernelPath
        self.logger = logger
    }

    /// Start the daemon server
    public func start() async throws {
        logger.info("Starting Arca daemon", metadata: [
            "socket_path": "\(socketPath)",
            "api_version": "1.51"
        ])

        // Load and validate configuration
        let configManager = ConfigManager(logger: logger)
        var config = try configManager.loadConfig()

        // Override kernel path if provided via command line
        if let kernelPath = self.kernelPath {
            config = ArcaConfig(
                kernelPath: kernelPath,
                socketPath: config.socketPath,
                logLevel: config.logLevel
            )
        }

        logger.info("Configuration loaded", metadata: [
            "kernel_path": "\(config.kernelPath)",
            "socket_path": "\(config.socketPath)",
            "log_level": "\(config.logLevel)"
        ])

        // Validate that kernel exists
        try configManager.validateConfig(config)

        // Check if socket already exists (daemon might be running)
        if ArcaServer.socketExists(at: socketPath) {
            logger.warning("Socket file already exists", metadata: [
                "socket_path": "\(socketPath)"
            ])
            // Try to remove it, if we can't, the daemon might be running
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                throw DaemonError.socketAlreadyExists(socketPath)
            }
        }

        // Initialize ImageManager
        let imageManager = try ImageManager(logger: logger, imageStorePath: nil)
        self.imageManager = imageManager

        do {
            try await imageManager.initialize()
        } catch {
            logger.warning("ImageManager initialization incomplete", metadata: [
                "error": "\(error)"
            ])
            // Continue anyway - we can still serve API requests
        }

        // Load custom vminit image BEFORE creating any ContainerManagers
        // This ensures both helper VM and main ContainerManager use the same vminit
        let vminitPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca")
            .appendingPathComponent("vminit")

        var initfsReference = "vminit:latest"  // Default reference

        if FileManager.default.fileExists(atPath: vminitPath.path) {
            logger.info("Loading custom vminit image from OCI layout", metadata: [
                "path": "\(vminitPath.path)"
            ])

            // Delete the existing initfs.ext4 file to force regeneration from our custom vminit
            // Without this, the old initfs.ext4 (which may be from a different vminit) gets reused
            //
            // Bound to the store this daemon actually loads into, rather than
            // spelled out from the home directory a second time: Containerization
            // builds initfs.ext4 at the image store's own path, so the two are the
            // same file only for as long as the two spellings agree. Unchanged in
            // effect -- the ImageManager above is constructed with no path, so its
            // store is ImageStore.default, rooted at Application Support's
            // com.apple.containerization (ImageStore.swift:55-64).
            let initfsPath = imageManager.storeRoot.appendingPathComponent("initfs.ext4")
            if FileManager.default.fileExists(atPath: initfsPath.path) {
                logger.debug("Deleting existing initfs.ext4 to force regeneration")
                do {
                    try FileManager.default.removeItem(at: initfsPath)
                    logger.debug("Deleted old initfs.ext4 successfully")
                } catch {
                    logger.warning("Failed to delete old initfs.ext4", metadata: [
                        "error": "\(error)"
                    ])
                }
            }

            // Delete existing arca-vminit image to force reload
            if await imageManager.imageExists(nameOrId: "arca-vminit:latest") {
                logger.debug("Deleting existing arca-vminit:latest to reload fresh version")
                _ = try? await imageManager.deleteImage(nameOrId: "arca-vminit:latest", force: true)
            }

            // Load the OCI layout into ImageStore
            // The OCI layout already has the image tagged as "arca-vminit:latest" via the index annotation
            do {
                let loadedImages = try await imageManager.loadFromOCILayout(directory: vminitPath)
                logger.info("Custom vminit image loaded successfully", metadata: [
                    "count": "\(loadedImages.count)",
                    "images": "\(loadedImages.map { $0.reference }.joined(separator: ", "))"
                ])

                // Verify the image was loaded with the correct reference
                if let firstImage = loadedImages.first {
                    if firstImage.reference == "arca-vminit:latest" {
                        initfsReference = "arca-vminit:latest"
                        logger.info("Custom vminit ready to use: \(initfsReference)")
                    } else {
                        logger.warning("Loaded vminit has unexpected reference: \(firstImage.reference)")
                    }
                }
            } catch {
                logger.warning("Failed to load custom vminit, will use default", metadata: [
                    "error": "\(error)"
                ])
            }
        } else {
            logger.warning("Custom vminit not found at \(vminitPath.path), will use default vminit")
        }

        // Control plane / Helper VM is NO LONGER USED
        // WireGuard backend runs services directly in each container VM - no central control plane needed

        // Initialize StateStore (shared by ContainerManager and NetworkManager)
        let stateDBPath = NSString(string: "~/.arca/state.db").expandingTildeInPath
        let stateStore: StateStore
        do {
            stateStore = try StateStore(path: stateDBPath, logger: logger)
            logger.info("StateStore initialized", metadata: ["path": "\(stateDBPath)"])
        } catch {
            logger.error("Failed to initialize StateStore", metadata: ["error": "\(error)"])
            throw error
        }

        // Initialize EventManager (shared by all managers for event emission)
        logger.info("Initializing event manager...")
        let eventManager = EventManager(logger: logger)
        self.eventManager = eventManager

        // The log root this daemon has always used, now stated here instead of
        // derived inside ContainerLogManager -- where every ContainerManager
        // got it, whatever state root it was built for.
        //
        // `url(for:in:appropriateFor:create:)` and not `urls(for:in:).first!`:
        // the force-unwrap the comment below warns about was still live in
        // ContainerLogManager, and this is the throwing spelling of the same
        // lookup. Same directory as before -- Application Support in the user
        // domain, then `com.apple.arca/logs` -- so nothing this daemon reads or
        // writes moves.
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let daemonLogRoot = applicationSupport
            .appendingPathComponent("com.apple.arca")
            .appendingPathComponent("logs")

        // Initialize ContainerManager with kernel path from config
        let containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            // ImageStore.default.path rather than a re-derivation of Apple's
            // path: re-deriving it would silently diverge the day Apple changes
            // it, and a hand-rolled `urls(for:in:)[0]` traps on an empty array
            // where ImageStore.defaultRoot() throws.
            imageStoreRoot: ImageStore.default.path,
            layerCachePath: URL(
                fileURLWithPath: NSString(string: "~/.arca/layers").expandingTildeInPath
            ),
            logRoot: daemonLogRoot,
            stateStore: stateStore,
            logger: logger
        )
        self.containerManager = containerManager

        // Initialize ExecManager (needed for health checks)
        let execManager = ExecManager(containerManager: containerManager, logger: logger)
        self.execManager = execManager

        // Initialize HealthChecker BEFORE containerManager.initialize()
        // This ensures health checks are available when containers are auto-restarted via restart policies
        logger.info("Initializing health checker...")
        let healthChecker = HealthChecker(logger: logger, execManager: execManager)
        await containerManager.setHealthChecker(healthChecker)
        logger.debug("ContainerManager configured with HealthChecker")

        // Wire up EventManager for Docker event emission
        await containerManager.setEventEmitter(eventManager)
        logger.debug("ContainerManager configured with EventManager")

        await imageManager.setEventEmitter(eventManager)
        logger.debug("ImageManager configured with EventManager")

        // Now initialize ContainerManager - this will restore containers and apply restart policies
        // Health checks will be started automatically for containers with healthcheck config
        do {
            try await containerManager.initialize()
        } catch {
            logger.error("ContainerManager initialization failed", metadata: [
                "error": "\(error)"
            ])
            throw error
        }

        // Initialize NetworkManager with WireGuard backend
        logger.info("Initializing network manager (WireGuard default)...")
        let nm = NetworkManager(
            config: config,
            stateStore: stateStore,
            containerManager: containerManager,
            logger: logger
        )
        self.networkManager = nm
        var networkManager: NetworkManager? = nm

        // Wire up EventManager for network events
        await nm.setEventEmitter(eventManager)
        logger.debug("NetworkManager configured with EventManager")

        do {
            try await nm.initialize()
            logger.info("Network manager initialized successfully")

            // Wire up NetworkManager reference in ContainerManager for auto-attachment
            await containerManager.setNetworkManager(nm)
            logger.debug("ContainerManager configured with NetworkManager")
        } catch {
            logger.error("Failed to initialize network manager", metadata: [
                "error": "\(error)"
            ])
            // Continue without network manager - networking features won't be available
            logger.warning("Daemon will continue without network manager - networking features disabled")
            self.networkManager = nil
            networkManager = nil
        }

        // Initialize VolumeManager
        let vm = VolumeManager(
            volumesBasePath: nil,  // Use default ~/.arca/volumes
            stateStore: stateStore,
            logger: logger
        )
        self.volumeManager = vm
        var volumeManager: VolumeManager? = vm

        do {
            try await vm.initialize()
            logger.info("Volume manager initialized successfully")

            // Wire up VolumeManager reference in ContainerManager for named volume resolution
            await containerManager.setVolumeManager(vm)
            logger.debug("ContainerManager configured with VolumeManager")
        } catch {
            logger.error("Failed to initialize volume manager", metadata: [
                "error": "\(error)"
            ])
            // Continue without volume manager - volume features won't be available
            logger.warning("Daemon will continue without volume manager - volume features disabled")
            self.volumeManager = nil
            volumeManager = nil
        }

        // Initialize PortMapManager (Phase 4.1 - Port Mapping)
        logger.info("Initializing port mapping manager...")
        let dumpNftables = config.logLevel.lowercased() == "debug"
        let portMapManager = PortMapManager(logger: logger, dumpNftablesOnPublish: dumpNftables)
        await containerManager.setPortMapManager(portMapManager)
        logger.debug("ContainerManager configured with PortMapManager")

        // Apply restart policies in background - don't block daemon startup!
        // All managers are wired up, so containers can restart now
        Task { [containerManager, logger] in
            logger.info("Applying restart policies to containers (background)...")
            do {
                try await containerManager.applyRestartPolicies()
                logger.info("Restart policies applied successfully")
            } catch {
                logger.error("Failed to apply restart policies", metadata: [
                    "error": "\(error)"
                ])
            }
        }

        // Create router builder, register middlewares and routes
        let builder = Router.builder(logger: logger)
            .use(RequestLogger(logger: logger))
            .use(APIVersionNormalizer())
        registerRoutes(
            builder: builder,
            containerManager: containerManager,
            imageManager: imageManager,
            execManager: execManager,
            networkManager: networkManager,
            volumeManager: volumeManager,
            eventManager: eventManager
        )
        let router = builder.build()

        // Create and start server
        let server = ArcaServer(socketPath: socketPath, router: router, execManager: execManager, containerManager: containerManager, logger: logger)
        self.server = server

        try await server.start()
    }

    /// Stop the daemon server
    public func shutdown() async throws {
        logger.info("Stopping Arca daemon")

        guard let server = server else {
            logger.warning("Server not running")
            return
        }

        // Gracefully shutdown ContainerManager (wait for monitoring tasks)
        if let containerManager = containerManager {
            logger.info("Gracefully shutting down ContainerManager...")
            await containerManager.shutdown()
        }

        try await server.shutdown()
        self.server = nil

        // Control plane is now a regular container with restart policy "always"
        // ContainerManager handles graceful shutdown via SIGTERM
        // No special cleanup needed

        logger.info("Arca daemon stopped")
    }

    /// Register all API routes
    private func registerRoutes(
        builder: RouterBuilder,
        containerManager: ContainerBridge.ContainerManager,
        imageManager: ImageManager,
        execManager: ExecManager,
        networkManager: NetworkManager?,
        volumeManager: VolumeManager?,
        eventManager: EventManager
    ) {
        logger.info("Registering API routes")

        // Create handlers
        let containerHandlers = ContainerHandlers(containerManager: containerManager, imageManager: imageManager, execManager: execManager, logger: logger)
        let imageHandlers = ImageHandlers(imageManager: imageManager, logger: logger)
        let execHandlers = ExecHandlers(execManager: execManager, logger: logger)
        let networkHandlers = networkManager.map { NetworkHandlers(networkManager: $0, containerManager: containerManager, logger: logger) }
        let volumeHandlers = volumeManager.map { VolumeHandlers(volumeManager: $0, logger: logger) }
        let systemHandlers = SystemHandlers(containerManager: containerManager, imageManager: imageManager)
        let eventHandlers = EventHandlers(eventManager: eventManager)

        // System endpoints - Ping (GET and HEAD)
        _ = builder.get("/_ping") { _ in
            let response = SystemHandlers.handlePing()
            let body = Data("OK".utf8)
            var headers = HTTPHeaders()
            headers.add(name: "API-Version", value: response.apiVersion)
            headers.add(name: "OSType", value: response.osType)
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(body.count)")
            return .standard(HTTPResponse(status: .ok, headers: headers, body: body))
        }

        _ = builder.head("/_ping") { _ in
            let response = SystemHandlers.handlePing()
            var headers = HTTPHeaders()
            headers.add(name: "API-Version", value: response.apiVersion)
            headers.add(name: "OSType", value: response.osType)
            headers.add(name: "Content-Length", value: "0")
            return .standard(HTTPResponse(status: .ok, headers: headers, body: nil))
        }

        _ = builder.get("/version") { _ in
            let response = SystemHandlers.handleVersion()
            return .standard(HTTPResponse.json(response))
        }

        _ = builder.get("/info") { _ in
            let response = await systemHandlers.handleInfo()
            return .standard(HTTPResponse.json(response))
        }

        // Events endpoint - Stream real-time events
        _ = builder.get("/events") { request in
            let since = request.queryString("since")
            let until = request.queryString("until")
            let filters = request.queryString("filters")

            let eventStream = await eventHandlers.handleEvents(
                since: since,
                until: until,
                filters: filters
            )

            // Stream events as newline-delimited JSON
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Transfer-Encoding", value: "chunked")

            return .streaming(status: .ok, headers: headers) { writer in
                for await event in eventStream {
                    // Encode event as JSON
                    if let jsonData = try? JSONEncoder().encode(event) {
                        var line = String(data: jsonData, encoding: .utf8) ?? ""
                        line += "\n"
                        do {
                            try await writer.write(Data(line.utf8))
                        } catch {
                            // Client disconnected or write failed - stop streaming
                            break
                        }
                    }
                }
            }
        }

        // Container endpoints - List
        _ = builder.get("/containers/json") { request in
            // Validate and parse query parameters
            do {
                let all = QueryParameterValidator.parseBoolean(request.queryParameters["all"])
                let limit = try QueryParameterValidator.parsePositiveInt(request.queryParameters["limit"], paramName: "limit")
                let size = QueryParameterValidator.parseBoolean(request.queryParameters["size"])
                let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

                // Call handler asynchronously
                let listResponse = await containerHandlers.handleListContainers(
                    all: all,
                    limit: limit,
                    size: size,
                    filters: filters
                )

                if let error = listResponse.error {
                    return .standard(HTTPResponse.internalServerError(
                        "Failed to list containers: \(error.localizedDescription)"
                    ))
                }

                return .standard(HTTPResponse.ok(listResponse.containers))
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid query parameters: \(error.localizedDescription)"))
            }
        }

        // Container endpoints - Create
        _ = builder.post("/containers/create") { request in
            // Parse container name from query parameters
            let name = request.queryString("name")

            // Parse JSON body
            do {
                let createRequest = try request.jsonBody(ContainerCreateRequest.self)

                // Call handler
                let result = await containerHandlers.handleCreateContainer(request: createRequest, name: name)

                switch result {
                case .success(let response):
                    return .standard(HTTPResponse.created(response))
                case .failure(let error):
                    // Return 404 for image not found so Docker CLI knows to pull
                    if case .imageNotFound = error {
                        return .standard(HTTPResponse.notFound(error.description))
                    }
                    // Return 409 Conflict for name already in use
                    if case .nameAlreadyInUse = error {
                        return .standard(HTTPResponse.error(error.description, status: .conflict))
                    }
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
            }
        }

        // Container endpoints - Start
        _ = builder.post("/containers/{id}/start") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let result = await containerHandlers.handleStartContainer(id: id)

            switch result {
            case .success:
                return .standard(HTTPResponse.noContent())
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container endpoints - Stop
        _ = builder.post("/containers/{id}/stop") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Validate timeout parameter
            do {
                let timeout = try QueryParameterValidator.parseNonNegativeInt(request.queryParameters["t"], paramName: "t")

                let result = await containerHandlers.handleStopContainer(id: id, timeout: timeout)

                switch result {
                case .success:
                    return .standard(HTTPResponse.noContent())
                case .failure(let error):
                    // Map ContainerError to appropriate HTTP status
                    switch error {
                    case .notFound:
                        return .standard(HTTPResponse.notFound(error.description))
                    default:
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                }
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid query parameters: \(error.localizedDescription)"))
            }
        }

        // Phase 5 - Task 5.4: Kill endpoint
        _ = builder.post("/containers/{id}/kill") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Get signal parameter (default: SIGKILL)
            let signal = request.queryString("signal") ?? "SIGKILL"

            let result = await containerHandlers.handleKillContainer(id: id, signal: signal)

            switch result {
            case .success:
                return .standard(HTTPResponse.noContent())
            case .failure(let error):
                // Map ContainerError to appropriate HTTP status
                switch error {
                case .notFound:
                    return .standard(HTTPResponse.notFound(error.description))
                case .invalidRequest:
                    // Container not running -> 409 Conflict (per Docker API spec)
                    return .standard(HTTPResponse.conflict(error.description))
                case .operationNotPermitted:
                    return .standard(HTTPResponse.forbidden(error.description))
                default:
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            }
        }

        _ = builder.post("/containers/{id}/restart") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Validate timeout parameter
            do {
                let timeout = try QueryParameterValidator.parseNonNegativeInt(request.queryParameters["t"], paramName: "t")

                let result = await containerHandlers.handleRestartContainer(id: id, timeout: timeout)

                switch result {
                case .success:
                    return .standard(HTTPResponse.noContent())
                case .failure(let error):
                    // Map ContainerError to appropriate HTTP status
                    switch error {
                    case .notFound:
                        return .standard(HTTPResponse.notFound(error.description))
                    case .operationNotPermitted:
                        return .standard(HTTPResponse.conflict(error.description))
                    default:
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                }
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid query parameters: \(error.localizedDescription)"))
            }
        }

        // Container endpoints - Rename
        _ = builder.post("/containers/{id}/rename") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            guard let newName = request.queryString("name") else {
                return .standard(HTTPResponse.badRequest("Missing required parameter: name"))
            }

            let result = await containerHandlers.handleRenameContainer(id: id, newName: newName)

            switch result {
            case .success:
                return .standard(HTTPResponse.noContent())
            case .failure(let error):
                // Map ContainerError to appropriate HTTP status
                switch error {
                case .notFound:
                    return .standard(HTTPResponse.notFound(error.description))
                case .nameAlreadyInUse:
                    return .standard(HTTPResponse.conflict(error.description))
                case .operationNotPermitted:
                    return .standard(HTTPResponse.conflict(error.description))
                default:
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            }
        }

        // Phase 6 - Task 6.1: Update endpoint
        _ = builder.post("/containers/{id}/update") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Parse request body
            do {
                let updateRequest = try request.jsonBody(ContainerUpdateRequest.self)
                let result = await containerHandlers.handleUpdateContainer(id: id, request: updateRequest)

                switch result {
                case .success(let response):
                    return .standard(HTTPResponse.ok(response))
                case .failure(let error):
                    // Map ContainerError to appropriate HTTP status
                    switch error {
                    case .notFound:
                        return .standard(HTTPResponse.notFound(error.description))
                    case .invalidRequest:
                        return .standard(HTTPResponse.badRequest(error.description))
                    default:
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                }
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid request body: \(error.localizedDescription)"))
            }
        }

        // Container endpoints - Pause
        _ = builder.post("/containers/{id}/pause") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let result = await containerHandlers.handlePauseContainer(id: id)

            switch result {
            case .success:
                return .standard(HTTPResponse.noContent())
            case .failure(let error):
                // Map ContainerError to appropriate HTTP status
                switch error {
                case .notFound:
                    return .standard(HTTPResponse.notFound(error.description))
                case .invalidRequest:
                    return .standard(HTTPResponse.conflict(error.description))
                default:
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            }
        }

        // Container endpoints - Unpause
        _ = builder.post("/containers/{id}/unpause") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let result = await containerHandlers.handleUnpauseContainer(id: id)

            switch result {
            case .success:
                return .standard(HTTPResponse.noContent())
            case .failure(let error):
                // Map ContainerError to appropriate HTTP status
                switch error {
                case .notFound:
                    return .standard(HTTPResponse.notFound(error.description))
                case .invalidRequest:
                    return .standard(HTTPResponse.conflict(error.description))
                default:
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            }
        }

        // Container endpoints - Stats
        _ = builder.get("/containers/{id}/stats") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Parse stream parameter (default: true in Docker API)
            let stream = request.queryParameters["stream"] != "false" && request.queryParameters["stream"] != "0"

            return await containerHandlers.handleGetContainerStatsStreaming(id: id, stream: stream)
        }

        // Container endpoints - Top (list processes)
        _ = builder.get("/containers/{id}/top") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let psArgs = request.queryString("ps_args")

            let result = await containerHandlers.handleTopContainer(id: id, psArgs: psArgs)

            switch result {
            case .success(let topResponse):
                return .standard(HTTPResponse.ok(topResponse))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container endpoints - Remove
        _ = builder.delete("/containers/{id}") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let force = request.queryParameters["force"] == "true" || request.queryParameters["force"] == "1"
            let volumes = request.queryParameters["v"] == "true" || request.queryParameters["v"] == "1"

            let result = await containerHandlers.handleRemoveContainer(id: id, force: force, removeVolumes: volumes)

            switch result {
            case .success:
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                return .standard(HTTPResponse(status: .noContent, headers: headers))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container endpoints - Inspect
        _ = builder.get("/containers/{id}/json") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let result = await containerHandlers.handleInspectContainer(id: id)

            switch result {
            case .success(let inspect):
                return .standard(HTTPResponse.json(inspect))
            case .failure(let error):
                // Return 404 for .notFound errors, 500 for everything else
                let status: HTTPResponseStatus
                if case .notFound = error {
                    status = .notFound
                } else {
                    status = .internalServerError
                }
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container endpoints - Logs
        _ = builder.get("/containers/{id}/logs") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Validate query parameters
            do {
                let stdout = QueryParameterValidator.parseBooleanDefaultTrue(request.queryParameters["stdout"])
                let stderr = QueryParameterValidator.parseBooleanDefaultTrue(request.queryParameters["stderr"])
                let follow = QueryParameterValidator.parseBoolean(request.queryParameters["follow"])
                let timestamps = QueryParameterValidator.parseBoolean(request.queryParameters["timestamps"])
                let since = try QueryParameterValidator.parseUnixTimestamp(request.queryParameters["since"], paramName: "since")
                let until = try QueryParameterValidator.parseUnixTimestamp(request.queryParameters["until"], paramName: "until")
                let tail = try QueryParameterValidator.parseTail(request.queryParameters["tail"])

                // Use streaming handler which supports both streaming and standard responses
                return await containerHandlers.handleLogsContainerStreaming(
                    idOrName: id,
                    stdout: stdout,
                    stderr: stderr,
                    follow: follow,
                    since: since,
                    until: until,
                    timestamps: timestamps,
                    tail: tail
                )
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.error("Invalid query parameters: \(error.localizedDescription)", status: .badRequest))
            }
        }

        _ = builder.post("/containers/{id}/attach") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Parse parameters - stdout/stderr/logs default to true if not specified (matches Docker behavior)
            let stdout = QueryParameterValidator.parseBooleanDefaultTrue(request.queryParameters["stdout"])
            let stderr = QueryParameterValidator.parseBooleanDefaultTrue(request.queryParameters["stderr"])
            let stream = QueryParameterValidator.parseBoolean(request.queryParameters["stream"])
            // logs defaults to TRUE - include historical logs unless explicitly disabled with logs=0
            let logs = QueryParameterValidator.parseBooleanDefaultTrue(request.queryParameters["logs"])

            // If logs=1 (or not specified), send all historical logs
            // If logs=0 explicitly, skip historical logs (only send new output)
            // If stream=1, follow for new output after historical logs
            let sinceTimestamp: Int? = if !logs {
                Int(Date().timeIntervalSince1970)  // Only new logs from now (when logs=0)
            } else {
                nil  // All historical logs (default behavior)
            }

            return await containerHandlers.handleLogsContainerStreaming(
                idOrName: id,
                stdout: stdout,
                stderr: stderr,
                follow: stream,
                since: sinceTimestamp,
                until: nil as Int?,
                timestamps: false,
                tail: nil as String?
            )
        }

        _ = builder.post("/containers/{id}/wait") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Wait for container to exit and return exit code
            let result = await containerHandlers.handleWaitContainer(idOrName: id)

            switch result {
            case .success(let exitCode):
                let response = ["StatusCode": exitCode]
                return .standard(HTTPResponse.json(response))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        _ = builder.post("/containers/{id}/resize") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let height = request.queryParameters["h"].flatMap { Int($0) }
            let width = request.queryParameters["w"].flatMap { Int($0) }

            let result = await containerHandlers.handleResizeContainer(id: id, height: height, width: width)

            switch result {
            case .success:
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                return .standard(HTTPResponse(status: .ok, headers: headers))
            case .failure(let error):
                return .standard(HTTPResponse.error(error.description, status: .internalServerError))
            }
        }

        // Exec endpoints
        _ = builder.post("/containers/{id}/exec") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Parse JSON body
            guard let body = request.body,
                  let execConfig = try? JSONDecoder().decode(ExecConfig.self, from: body) else {
                return .standard(HTTPResponse.error("Invalid or missing request body", status: .badRequest))
            }

            let result = await execHandlers.handleCreateExec(containerID: id, config: execConfig)

            switch result {
            case .success(let response):
                return .standard(HTTPResponse.json(response, status: .created))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not running") ? .conflict : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        _ = builder.post("/exec/{id}/start") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing exec ID"))
            }

            // Parse JSON body
            guard let body = request.body,
                  let startConfig = try? JSONDecoder().decode(ExecStartConfig.self, from: body) else {
                return .standard(HTTPResponse.error("Invalid or missing request body", status: .badRequest))
            }

            // Handler returns HTTPResponseType directly (streaming or standard)
            return await execHandlers.handleStartExec(execID: id, config: startConfig)
        }

        // Exec endpoints - Resize
        _ = builder.post("/exec/{id}/resize") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing exec ID"))
            }

            let height = request.queryParameters["h"].flatMap(Int.init)
            let width = request.queryParameters["w"].flatMap(Int.init)

            return await execHandlers.handleResizeExec(execID: id, height: height, width: width)
        }

        // Exec endpoints - Inspect
        _ = builder.get("/exec/{id}/json") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing exec ID"))
            }

            let result = await execHandlers.handleInspectExec(execID: id)

            switch result {
            case .success(let inspect):
                return .standard(HTTPResponse.json(inspect))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container endpoints - Prune
        _ = builder.post("/containers/prune") { request in
            do {
                let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

                let result = await containerHandlers.handlePruneContainers(filters: filters)

                switch result {
                case .success(let response):
                    return .standard(HTTPResponse.json(response))
                case .failure(let error):
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid filters parameter: \(error.localizedDescription)"))
            }
        }

        // Container archive endpoints - for buildx docker-container driver
        _ = builder.get("/containers/{id}/archive") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            guard let path = request.queryString("path") else {
                return .standard(HTTPResponse.badRequest("Missing path parameter"))
            }

            let result = await containerHandlers.handleGetArchive(id: id, path: path)
            switch result {
            case .success(let (tarData, stat)):
                // Create JSON for X-Docker-Container-Path-Stat header
                let statJSON: [String: Any] = [
                    "name": stat.name,
                    "size": stat.size,
                    "mode": stat.mode,
                    "mtime": stat.mtime,
                    "linkTarget": stat.linkTarget
                ]

                guard let jsonData = try? JSONSerialization.data(withJSONObject: statJSON),
                      let base64Stat = String(data: jsonData.base64EncodedData(), encoding: .utf8) else {
                    return .standard(HTTPResponse.internalServerError("Failed to encode path stat"))
                }

                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "application/x-tar")
                headers.add(name: "X-Docker-Container-Path-Stat", value: base64Stat)
                return .standard(HTTPResponse(
                    status: .ok,
                    headers: headers,
                    body: tarData
                ))
            case .failure(let error):
                let status: HTTPResponseStatus
                if case .notFound = error {
                    status = .notFound
                } else {
                    status = .internalServerError
                }
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        _ = builder.head("/containers/{id}/archive") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            guard let path = request.queryString("path") else {
                return .standard(HTTPResponse.badRequest("Missing path parameter"))
            }

            // HEAD endpoint returns same stat header as GET but without body
            let result = await containerHandlers.handleGetArchive(id: id, path: path)
            switch result {
            case .success(let (_, stat)):
                // Create JSON for X-Docker-Container-Path-Stat header
                let statJSON: [String: Any] = [
                    "name": stat.name,
                    "size": stat.size,
                    "mode": stat.mode,
                    "mtime": stat.mtime,
                    "linkTarget": stat.linkTarget
                ]

                guard let jsonData = try? JSONSerialization.data(withJSONObject: statJSON),
                      let base64Stat = String(data: jsonData.base64EncodedData(), encoding: .utf8) else {
                    return .standard(HTTPResponse.internalServerError("Failed to encode path stat"))
                }

                var headers = HTTPHeaders()
                headers.add(name: "X-Docker-Container-Path-Stat", value: base64Stat)
                return .standard(HTTPResponse(
                    status: .ok,
                    headers: headers,
                    body: nil  // HEAD returns no body
                ))
            case .failure(let error):
                let status: HTTPResponseStatus
                if case .notFound = error {
                    status = .notFound
                } else {
                    status = .internalServerError
                }
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        _ = builder.put("/containers/{id}/archive") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            guard let path = request.queryString("path") else {
                return .standard(HTTPResponse.badRequest("Missing path parameter"))
            }

            guard let tarData = request.body else {
                return .standard(HTTPResponse.badRequest("Missing request body (tar archive)"))
            }

            let result = await containerHandlers.handlePutArchive(id: id, path: path, tarData: tarData)
            switch result {
            case .success:
                return .standard(HTTPResponse(status: .ok, headers: HTTPHeaders(), body: nil))
            case .failure(let error):
                let status: HTTPResponseStatus
                if case .notFound = error {
                    status = .notFound
                } else {
                    status = .internalServerError
                }
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container diff endpoint - Phase 6 Task 6.4
        _ = builder.get("/containers/{id}/changes") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let result = await containerHandlers.handleContainerChanges(id: id)
            switch result {
            case .success(let changes):
                return .standard(HTTPResponse.ok(changes))
            case .failure(let error):
                let status: HTTPResponseStatus
                switch error {
                case .notFound:
                    status = .notFound
                case .invalidRequest:
                    status = .badRequest
                default:
                    status = .internalServerError
                }
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Image endpoints
        _ = builder.get("/images/json") { request in
            // Validate and parse query parameters
            do {
                let all = QueryParameterValidator.parseBoolean(request.queryParameters["all"])
                let digests = QueryParameterValidator.parseBoolean(request.queryParameters["digests"])
                let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

                // Call handler asynchronously
                let listResponse = await imageHandlers.handleListImages(
                    all: all,
                    filters: filters,
                    digests: digests
                )

                if let error = listResponse.error {
                    return .standard(HTTPResponse.error(
                        "Failed to list images: \(error.localizedDescription)",
                        status: .internalServerError
                    ))
                }

                return .standard(HTTPResponse.json(listResponse.images))
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.error("Invalid query parameters: \(error.localizedDescription)", status: .badRequest))
            }
        }

        // Image inspect endpoint - uses greedy match to capture names with slashes
        _ = builder.get("/images/{name:.*}/json") { request in
            guard let name = request.pathParam("name") else {
                return .standard(HTTPResponse.badRequest("Missing image name"))
            }

            let result = await imageHandlers.handleInspectImage(nameOrId: name)

            switch result {
            case .success(let inspect):
                return .standard(HTTPResponse.ok(inspect))
            case .failure(let error):
                // Return 404 for image not found
                let status: HTTPResponseStatus
                if case .imageNotFound = error {
                    status = .notFound
                } else {
                    status = .internalServerError
                }
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        _ = builder.post("/images/create") { request in
            // Parse query parameters
            guard let fromImage = request.queryParameters["fromImage"] else {
                return .standard(HTTPResponse.error("Missing 'fromImage' query parameter", status: .badRequest))
            }

            let tag = request.queryParameters["tag"]
            let platform = request.queryParameters["platform"]

            // Parse authentication from X-Registry-Auth header
            var auth: RegistryAuthentication?
            if let authHeader = request.headers.first(name: "X-Registry-Auth") {
                if let authConfig = try? RegistryAuthConfig.fromBase64(authHeader) {
                    auth = RegistryAuthentication(
                        username: authConfig.username,
                        password: authConfig.password,
                        email: authConfig.email,
                        serverAddress: authConfig.serveraddress,
                        identityToken: authConfig.identitytoken,
                        registryToken: authConfig.registrytoken
                    )
                }
            }

            // Call streaming handler for real-time progress updates
            return await imageHandlers.handlePullImageStreaming(
                fromImage: fromImage,
                tag: tag,
                platform: platform,
                auth: auth
            )
        }

        // Image delete endpoint - uses greedy match to capture names with slashes
        _ = builder.delete("/images/{name:.*}") { request in
            guard let name = request.pathParam("name") else {
                return .standard(HTTPResponse.badRequest("Missing image name"))
            }

            let force = request.queryParameters["force"] == "true" || request.queryParameters["force"] == "1"
            let noprune = request.queryParameters["noprune"] == "true" || request.queryParameters["noprune"] == "1"

            let result = await imageHandlers.handleDeleteImage(nameOrId: name, force: force, noprune: noprune)

            switch result {
            case .success(let response):
                return .standard(HTTPResponse.json(response))
            case .failure(let error):
                // Return 404 for image not found, 500 for other errors
                let status: HTTPResponseStatus = {
                    if case .imageNotFound = error {
                        return .notFound
                    }
                    return .internalServerError
                }()
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Image prune endpoint
        _ = builder.post("/images/prune") { request in
            do {
                let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

                let result = await imageHandlers.handlePruneImages(filters: filters, containerManager: containerManager)

                switch result {
                case .success(let response):
                    return .standard(HTTPResponse.ok(response))
                case .failure(let error):
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid filters parameter: \(error.localizedDescription)"))
            }
        }

        // Image load endpoint - Load images from tar archive
        _ = builder.post("/images/load") { request in
            // Read tar data from request body
            guard let tarData = request.body else {
                return .standard(HTTPResponse.badRequest("Missing request body (tar archive required)"))
            }

            let result = await imageHandlers.handleLoadImage(tarData: tarData)

            switch result {
            case .success(let response):
                // Return streaming response (newline-delimited JSON like pull)
                let jsonData: Data
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .withoutEscapingSlashes
                    jsonData = try encoder.encode(response)
                } catch {
                    return .standard(HTTPResponse.internalServerError("Failed to encode response"))
                }

                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "application/json")
                return .standard(HTTPResponse(status: .ok, headers: headers, body: jsonData))
            case .failure(let error):
                return .standard(HTTPResponse.internalServerError(error.description))
            }
        }

        // Network endpoints
        if let networkHandlers = networkHandlers {
            _ = builder.get("/networks") { request in
                do {
                    let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

                    let result = await networkHandlers.handleListNetworks(filters: filters)

                    switch result {
                    case .success(let networks):
                        return .standard(HTTPResponse.ok(networks))
                    case .failure(let error):
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid filters parameter"))
                }
            }

            _ = builder.get("/networks/{id}") { request in
                guard let id = request.pathParam("id") else {
                    return .standard(HTTPResponse.badRequest("Missing network ID"))
                }

                let verbose = request.queryBool("verbose", default: false)
                let scope = request.queryString("scope")

                let result = await networkHandlers.handleInspectNetwork(
                    id: id,
                    verbose: verbose,
                    scope: scope
                )

                switch result {
                case .success(let network):
                    return .standard(HTTPResponse.ok(network))
                case .failure(let error):
                    if case .notFound = error {
                        return .standard(HTTPResponse.notFound(error.description))
                    }
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            }

            _ = builder.post("/networks/create") { request in
                do {
                    let createRequest = try request.jsonBody(NetworkCreateRequest.self)

                    let result = await networkHandlers.handleCreateNetwork(request: createRequest)

                    switch result {
                    case .success(let response):
                        return .standard(HTTPResponse.created(response))
                    case .failure(let error):
                        if case .conflict = error {
                            return .standard(HTTPResponse.conflict(error.description))
                        } else if case .invalidRequest = error {
                            return .standard(HTTPResponse.badRequest(error.description))
                        }
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
                }
            }

            _ = builder.delete("/networks/{id}") { request in
                guard let id = request.pathParam("id") else {
                    return .standard(HTTPResponse.badRequest("Missing network ID"))
                }

                let force = request.queryBool("force")

                let result = await networkHandlers.handleDeleteNetwork(id: id, force: force)

                switch result {
                case .success:
                    return .standard(HTTPResponse.noContent())
                case .failure(let error):
                    if case .notFound = error {
                        return .standard(HTTPResponse.notFound(error.description))
                    } else if case .conflict = error {
                        return .standard(HTTPResponse.conflict(error.description))
                    }
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            }

            _ = builder.post("/networks/{id}/connect") { request in
                guard let id = request.pathParam("id") else {
                    return .standard(HTTPResponse.badRequest("Missing network ID"))
                }

                do {
                    let connectRequest = try request.jsonBody(NetworkConnectRequest.self)

                    // Resolve container name/ID to full Docker ID
                    guard let dockerID = await containerManager.resolveContainerID(connectRequest.container) else {
                        return .standard(HTTPResponse.notFound("container", id: connectRequest.container))
                    }

                    // Get container name
                    let containerName = await containerManager.getContainerName(dockerID: dockerID) ?? dockerID

                    let result = await networkHandlers.handleConnectNetwork(
                        networkID: id,
                        containerID: dockerID,
                        containerName: containerName,
                        endpointConfig: connectRequest.endpointConfig
                    )

                    switch result {
                    case .success:
                        return .standard(HTTPResponse.json([String: String](), status: .ok))  // Docker returns empty object
                    case .failure(let error):
                        if case .notFound = error {
                            return .standard(HTTPResponse.notFound(error.description))
                        } else if case .conflict = error {
                            return .standard(HTTPResponse.conflict(error.description))
                        }
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
                }
            }

            _ = builder.post("/networks/{id}/disconnect") { request in
                guard let id = request.pathParam("id") else {
                    return .standard(HTTPResponse.badRequest("Missing network ID"))
                }

                do {
                    let disconnectRequest = try request.jsonBody(NetworkDisconnectRequest.self)

                    // Resolve container name/ID to full Docker ID
                    guard let dockerID = await containerManager.resolveContainerID(disconnectRequest.container) else {
                        return .standard(HTTPResponse.notFound("container", id: disconnectRequest.container))
                    }

                    let result = await networkHandlers.handleDisconnectNetwork(
                        networkID: id,
                        containerID: dockerID,
                        force: disconnectRequest.force ?? false
                    )

                    switch result {
                    case .success:
                        return .standard(HTTPResponse.json([String: String](), status: .ok))  // Docker returns empty object
                    case .failure(let error):
                        if case .notFound = error {
                            return .standard(HTTPResponse.notFound(error.description))
                        } else if case .conflict = error {
                            return .standard(HTTPResponse.conflict(error.description))
                        }
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
                }
            }

            _ = builder.post("/networks/prune") { request in
                do {
                    let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

                    let result = await networkHandlers.handlePruneNetworks(filters: filters)

                    switch result {
                    case .success(let response):
                        return .standard(HTTPResponse.ok(response))
                    case .failure(let error):
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid filters parameter"))
                }
            }
        }

        // Volume routes (if VolumeManager is available)
        if let volumeHandlers = volumeHandlers {
            // POST /volumes/create - Create volume
            _ = builder.post("/volumes/create") { request in
                do {
                    let createRequest = try request.jsonBody(VolumeCreateRequest.self)
                    let result = await volumeHandlers.handleCreateVolume(request: createRequest)

                    switch result {
                    case .success(let volume):
                        return .standard(HTTPResponse.created(volume))
                    case .failure(let error):
                        return .standard(HTTPResponse.error(error.description, status: error.statusCode))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
                }
            }

            // GET /volumes - List volumes
            _ = builder.get("/volumes") { request in
                do {
                    let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])
                    let result = await volumeHandlers.handleListVolumes(filters: filters)

                    switch result {
                    case .success(let response):
                        return .standard(HTTPResponse.ok(response))
                    case .failure(let error):
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid filters parameter"))
                }
            }

            // GET /volumes/{name} - Inspect volume
            _ = builder.get("/volumes/{name}") { request in
                guard let name = request.pathParam("name") else {
                    return .standard(HTTPResponse.badRequest("Missing volume name"))
                }

                let result = await volumeHandlers.handleInspectVolume(name: name)

                switch result {
                case .success(let volume):
                    return .standard(HTTPResponse.ok(volume))
                case .failure(let error):
                    return .standard(HTTPResponse.error(error.description, status: error.statusCode))
                }
            }

            // DELETE /volumes/{name} - Delete volume
            _ = builder.delete("/volumes/{name}") { request in
                guard let name = request.pathParam("name") else {
                    return .standard(HTTPResponse.badRequest("Missing volume name"))
                }

                let force = request.queryBool("force", default: false)
                let result = await volumeHandlers.handleDeleteVolume(name: name, force: force)

                switch result {
                case .success:
                    return .standard(HTTPResponse.noContent())
                case .failure(let error):
                    return .standard(HTTPResponse.error(error.description, status: error.statusCode))
                }
            }

            // POST /volumes/prune - Prune volumes
            _ = builder.post("/volumes/prune") { request in
                do {
                    let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])
                    let result = await volumeHandlers.handlePruneVolumes(filters: filters)

                    switch result {
                    case .success(let response):
                        return .standard(HTTPResponse.ok(response))
                    case .failure(let error):
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid filters parameter"))
                }
            }

            logger.info("Registered 28 routes (including 6 network routes, 5 volume routes)")
        } else if networkHandlers != nil {
            logger.info("Registered 23 routes (including 6 network routes, volume routes skipped)")
        } else {
            logger.info("Registered 17 routes (network and volume routes skipped)")
        }
    }

    /// Check if the daemon is running
    public static func isRunning(socketPath: String) -> Bool {
        return ArcaServer.socketExists(at: socketPath)
    }
}

// MARK: - Error Types

public enum DaemonError: Error, CustomStringConvertible {
    case socketAlreadyExists(String)
    case vmnetInitializationFailed(String)

    public var description: String {
        switch self {
        case .socketAlreadyExists(let path):
            return "Socket already exists at \(path). Is the daemon already running?"
        case .vmnetInitializationFailed(let message):
            return "Failed to initialize vmnet network: \(message)"
        }
    }
}
