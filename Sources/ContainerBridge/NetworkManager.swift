import Foundation
import Logging
import Containerization

/// A source `NetworkManager.listNetworks()` reads networks from.
///
/// `NetworkManager` owns this abstraction rather than the backend: it names the
/// one capability the listing needs, so a caller can supply a source that fails
/// without standing in for the rest of `WireGuardNetworkBackend`. `package`
/// because the only such caller is `ArcaEngineTests`, which is in this package;
/// nothing outside it has a reason to implement this.
package protocol NetworkLister: Sendable {
    func listNetworks() async throws -> [NetworkMetadata]
}

/// The `null`-driver networks, read from the StateStore.
///
/// A `NetworkLister` rather than an inline branch of `listNetworks()`. As a
/// branch it read each network back through `getNetwork(id:)`, whose `catch`
/// logs and returns `nil`, so a StateStore failure -- `SQLITE_BUSY` under a
/// concurrent write, say -- dropped every `--driver null` network from
/// `docker network ls` and still reported success. Read as a source, through
/// the same `try` as every other source, it has nowhere left to drop one.
struct NullDriverNetworks: NetworkLister {
    let stateStore: StateStore

    func listNetworks() async throws -> [NetworkMetadata] {
        try await stateStore.loadAllNetworks()
            .filter { $0.driver == "null" }
            .map(NetworkMetadata.init(persisted:))
    }
}

/// The source `NetworkManager` reads container attachments from -- both
/// directions of the same table: which containers are on a network, and which
/// networks a container is on.
///
/// A second seam rather than two more methods on `NetworkLister`. The two
/// protocols name different capabilities over different tables, and widening
/// `NetworkLister` would force `NullDriverNetworks` -- which knows only how to
/// list `--driver null` networks -- to carry two attachment methods it has no
/// answer for. It would also let one stub stand in for both concerns, and a
/// test that fails "some source" cannot say which read it proved. `package`
/// for the reason `NetworkLister` is: the only implementors outside this file
/// are in this package's tests.
package protocol NetworkAttachmentSource: Sendable {
    func getNetworkAttachments(networkID: String) async throws -> [String: NetworkAttachment]
    func getContainerNetworks(containerID: String) async throws -> [NetworkMetadata]
}

/// Attachments as the StateStore holds them.
///
/// This is where attachments actually live: `WireGuardNetworkBackend`'s two
/// methods of these names read `network_attachments` and nothing else -- no
/// in-memory backend state at all -- and `NetworkManager` was their only
/// caller. Reading the store directly, rather than through a backend that
/// `initialize()` alone can install, is what lets the production derivation be
/// driven with no stub in place: a test can seed a row and read it back
/// through the same code the daemon runs.
struct StoredNetworkAttachments: NetworkAttachmentSource {
    let stateStore: StateStore

    func getNetworkAttachments(networkID: String) async throws -> [String: NetworkAttachment] {
        var attachments: [String: NetworkAttachment] = [:]

        for stored in try await stateStore.loadAttachmentsForNetwork(networkID: networkID) {
            attachments[stored.containerID] = NetworkAttachment(
                networkID: networkID,
                ip: stored.ipAddress,
                mac: stored.macAddress,
                aliases: stored.aliases
            )
        }

        return attachments
    }

    func getContainerNetworks(containerID: String) async throws -> [NetworkMetadata] {
        let attachedIDs = try await stateStore.getContainerNetworks(containerID: containerID)
        var networks: [NetworkMetadata] = []

        for persisted in try await stateStore.loadAllNetworks() where attachedIDs.contains(persisted.id) {
            var network = NetworkMetadata(persisted: persisted)
            network.containers = try await stateStore.getNetworkContainers(networkID: persisted.id)
            networks.append(network)
        }

        return networks
    }
}

extension NetworkMetadata {
    /// One stored network as metadata. The single mapping from a persisted row,
    /// so `NullDriverNetworks` and `NetworkManager.getNetwork(id:)` cannot come
    /// to disagree about what a stored network means.
    ///
    /// Malformed `options`/`labels` JSON decodes to empty rather than throwing:
    /// that was the behaviour before this was extracted, and a network is still
    /// a network without its labels. A failure to *reach* the row is the one
    /// this task is about, and that is the caller's `try`.
    init(persisted network: StateStore.PersistedNetwork) {
        self.init(
            id: network.id,
            name: network.name,
            driver: network.driver,
            subnet: network.subnet,
            gateway: network.gateway,
            ipRange: network.ipRange,
            containers: [],  // Null networks don't track containers
            created: network.createdAt,
            options: Self.decodeStringMap(network.optionsJSON),
            labels: Self.decodeStringMap(network.labelsJSON),
            isDefault: network.isDefault
        )
    }

    private static func decodeStringMap(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

/// Manages Docker networks with WireGuard as the default bridge backend:
/// - WireGuard backend (default): Full Docker compatibility with ~1ms latency
/// - vmnet backend: High performance native vmnet (limited features, user-created only)
///
/// NetworkManager acts as a facade that delegates to the appropriate backend
/// based on user-specified driver type.
public actor NetworkManager {
    private let config: ArcaConfig
    private let logger: Logger
    private let stateStore: StateStore
    private let containerManager: ContainerManager
    private var eventEmitter: EventEmitter?

    // Backends
    private var vmnetBackend: VmnetNetworkBackend?
    private var wireGuardBackend: WireGuardNetworkBackend?

    /// Sources standing in for the two `listNetworks()` derives. `nil` in
    /// production and set only by the two `package` setters below, which exist
    /// because `listNetworks()` has no other reachable failure: the WireGuard
    /// backend is populated only by `initialize()`, which also creates the
    /// default `host` network over vmnet and so cannot run in a unit test, and
    /// `StateStore` is a concrete actor whose SQLite connection a test has no
    /// way to break deterministically.
    private var installedBridgeNetworkLister: (any NetworkLister)?
    private var installedNullNetworkLister: (any NetworkLister)?

    /// The source standing in for `StoredNetworkAttachments`. `nil` in
    /// production, and set only by the `package` setter below. Unlike the two
    /// listers above, the source this replaces *is* reachable without
    /// `initialize()` -- it reads the StateStore directly -- so the tests that
    /// matter most here install nothing at all. This exists for the one thing
    /// they cannot do: make that store read fail on demand.
    private var installedAttachmentSource: (any NetworkAttachmentSource)?

    /// The source the two attachment reads below derive from, and their only
    /// reader.
    ///
    /// Computed, not stored, for the reason `networkListers` is: a stored copy
    /// would have to be assigned somewhere, and dropping that assignment would
    /// leave production reading no attachments -- `docker network prune`
    /// deleting in-use networks -- with every test still green.
    private var attachmentSource: any NetworkAttachmentSource {
        installedAttachmentSource ?? StoredNetworkAttachments(stateStore: stateStore)
    }

    /// The sources `listNetworks()` reads, and its only reader.
    ///
    /// Computed rather than stored: a stored copy would have to be assigned
    /// alongside `wireGuardBackend` in `initialize()`, and dropping that one
    /// line would leave production listing no bridge networks with every test
    /// still green. Derived, a source cannot be installed without this seeing
    /// it.
    private var networkListers: [any NetworkLister] {
        var listers: [any NetworkLister] = []

        if let bridge = installedBridgeNetworkLister ?? wireGuardBackend {
            listers.append(bridge)
        }
        listers.append(
            installedNullNetworkLister ?? NullDriverNetworks(stateStore: stateStore)
        )

        return listers
    }

    // Central network routing: networkID -> driver
    // This avoids "try all backends" pattern and provides O(1) backend lookup
    private var networkDrivers: [String: String] = [:]
    private var networkNames: [String: String] = [:]  // name -> ID mapping

    /// Initialize NetworkManager with configuration
    public init(
        config: ArcaConfig,
        stateStore: StateStore,
        containerManager: ContainerManager,
        logger: Logger
    ) {
        self.config = config
        self.stateStore = stateStore
        self.containerManager = containerManager
        self.logger = logger
    }

    /// Set the EventEmitter for emitting Docker events
    public func setEventEmitter(_ emitter: EventEmitter) {
        self.eventEmitter = emitter
    }

    /// Install the bridge-network source `listNetworks()` reads, in place of
    /// the WireGuard backend, without the rest of `initialize()`.
    ///
    /// `package` rather than `public` for the reason `NetworkLister` is: this
    /// exists so `ArcaEngineTests` can drive `listNetworks()` against a backend
    /// that fails. The daemon has no use for it -- it calls `initialize()`,
    /// which installs the real backend itself.
    package func setBridgeNetworkLister(_ lister: any NetworkLister) {
        self.installedBridgeNetworkLister = lister
    }

    /// Install the `null`-driver source `listNetworks()` reads, in place of the
    /// StateStore-backed one. `package` for the same reason, and separate from
    /// the bridge setter so a test can fail one source while the other stands:
    /// a single setter for both would prove only that *some* source's failure
    /// surfaces, not that the null-driver read is one of the sources.
    package func setNullNetworkLister(_ lister: any NetworkLister) {
        self.installedNullNetworkLister = lister
    }

    /// Install the attachment source `getNetworkAttachments` and
    /// `getContainerNetworks` read, in place of the StateStore-backed one.
    ///
    /// `package` for the reason the two above are, and it exists for one
    /// purpose: `StateStore` is a concrete actor whose SQLite connection a test
    /// has no way to break deterministically, so a partial store failure -- the
    /// one that used to let `docker network prune` delete an in-use network --
    /// can be reproduced no other way. Production never calls this; it takes
    /// the `??` default in `attachmentSource`.
    package func setNetworkAttachmentSource(_ source: any NetworkAttachmentSource) {
        self.installedAttachmentSource = source
    }

    /// Initialize the network manager and backends
    public func initialize() async throws {
        logger.info("Initializing NetworkManager (WireGuard default)")

        // Always initialize WireGuard backend as the default
        let backend = WireGuardNetworkBackend(
            logger: logger,
            stateStore: stateStore,
            getContainer: { [weak self] containerID in
                guard let self = self else {
                    throw NetworkManagerError.containerNotFound(containerID)
                }
                guard let container = await self.containerManager.getNativeContainer(id: containerID) else {
                    throw NetworkManagerError.containerNotFound(containerID)
                }
                return container
            }
        )
        self.wireGuardBackend = backend

        logger.info("WireGuard backend initialized (default for bridge networks)")

        // vmnet backend is created on-demand when explicitly requested

        // Load network driver and name mappings from StateStore
        // This allows us to route network operations to the correct backend efficiently
        do {
            let persistedNetworks = try await stateStore.loadAllNetworks()
            for network in persistedNetworks {
                networkDrivers[network.id] = network.driver
                networkNames[network.name] = network.id
            }
            logger.info("Loaded network mappings", metadata: ["count": "\(networkDrivers.count)"])
        } catch {
            logger.error("Failed to load network mappings", metadata: ["error": "\(error)"])
            // Continue - backends will still work, just without persisted mappings
        }

        // Restore persisted networks into backend's in-memory state
        // This ensures networks created before daemon restart are available
        try await backend.restoreNetworks()

        // Create default networks (idempotent - only creates if they don't exist)
        try await createDefaultNetworks()

        logger.info("NetworkManager initialized successfully")
    }

    /// Create default Docker networks (bridge, host, none)
    /// This is idempotent - only creates networks that don't already exist
    private func createDefaultNetworks() async throws {
        logger.info("Creating default networks (if not exist)")

        // 1. Create "bridge" network (172.17.0.0/16 - Docker's default)
        if await getNetworkByName(name: "bridge") == nil {
            logger.info("Creating default 'bridge' network (172.17.0.0/16)")
            let _ = try await createNetwork(
                name: "bridge",
                driver: "bridge",
                subnet: "172.17.0.0/16",
                gateway: "172.17.0.1",
                ipRange: nil,
                options: [:],
                labels: [:],
                isDefault: true
            )
            logger.info("Created default 'bridge' network")
        } else {
            logger.info("Default 'bridge' network already exists")
        }

        // 2. Create "host" network (vmnet driver - Arca's host networking equivalent)
        // Apple's vmnet framework auto-allocates subnets (e.g., 192.168.64.0/24)
        // This provides direct host networking similar to Docker's "host" mode but with an IP
        // Also serves as the underlay for WireGuard bridge network traffic (firewalled)
        if await getNetworkByName(name: "host") == nil {
            logger.info("Creating default 'host' network (vmnet driver, auto-allocated subnet)")
            let _ = try await createNetwork(
                name: "host",
                driver: "vmnet",
                subnet: nil,  // Apple auto-allocates
                gateway: nil,  // Apple auto-allocates
                ipRange: nil,
                options: [:],
                labels: [:],
                isDefault: true
            )
            logger.info("Created default 'host' network")
        } else {
            logger.info("Default 'host' network already exists")
        }

        // 3. Create "none" network (null driver - no network interfaces)
        if await getNetworkByName(name: "none") == nil {
            logger.info("Creating default 'none' network (null driver)")
            let _ = try await createNetwork(
                name: "none",
                driver: "null",
                subnet: nil,
                gateway: nil,
                ipRange: nil,
                options: [:],
                labels: [:],
                isDefault: true
            )
            logger.info("Created default 'none' network")
        } else {
            logger.info("Default 'none' network already exists")
        }

        logger.info("Default networks created successfully")
    }

    // MARK: - Network CRUD Operations

    /// Create a new network
    public func createNetwork(
        name: String,
        driver: String?,
        subnet: String?,
        gateway: String?,
        ipRange: String?,
        options: [String: String],
        labels: [String: String],
        isDefault: Bool = false
    ) async throws -> String {
        // Determine effective driver (explicit driver or "bridge" as default)
        // Normalize empty string to nil (Docker Compose and other clients may send "")
        let normalizedDriver = driver?.isEmpty == false ? driver : nil
        let effectiveDriver = normalizedDriver ?? "bridge"

        // Generate network ID
        let networkID = generateNetworkID()

        logger.info("Creating network", metadata: [
            "name": "\(name)",
            "driver": "\(effectiveDriver)",
            "network_id": "\(networkID)"
        ])

        // Validate network name
        guard !name.isEmpty else {
            throw NetworkManagerError.invalidName("Network name cannot be empty")
        }

        // Route to appropriate backend
        switch effectiveDriver {
        case "bridge", "wireguard":
            // Bridge networks always use WireGuard backend
            // "wireguard" is an alias for "bridge" for backwards compatibility
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.backendNotReady
            }

            let metadata = try await backend.createBridgeNetwork(
                id: networkID,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels,
                isDefault: isDefault
            )

            // Register in mappings
            networkDrivers[networkID] = "bridge"  // Always register as "bridge"
            networkNames[name] = networkID

            return metadata.id

        case "vmnet":
            // Explicitly requested vmnet driver
            if vmnetBackend == nil {
                // If vmnet backend not initialized, create it on-demand
                let backend = VmnetNetworkBackend(logger: logger)
                self.vmnetBackend = backend
            }

            let metadata = try await vmnetBackend!.createBridgeNetwork(
                id: networkID,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels,
                isDefault: isDefault
            )

            // Register in mappings
            networkDrivers[networkID] = metadata.driver
            networkNames[name] = networkID

            return metadata.id

        case "null":
            // "null" driver - no network interfaces attached to containers
            // Used for the default "none" network
            let createdDate = Date()

            // Persist to StateStore
            let optionsJSON = try JSONEncoder().encode(options)
            let labelsJSON = try JSONEncoder().encode(labels)

            try await stateStore.saveNetwork(
                id: networkID,
                name: name,
                driver: "null",
                scope: "local",
                createdAt: createdDate,
                subnet: "",
                gateway: "",
                ipRange: nil,
                optionsJSON: String(data: optionsJSON, encoding: .utf8),
                labelsJSON: String(data: labelsJSON, encoding: .utf8),
                isDefault: isDefault
            )

            // Register in mappings
            networkDrivers[networkID] = "null"
            networkNames[name] = networkID

            logger.info("Created null network", metadata: ["name": "\(name)", "id": "\(networkID)"])

            return networkID

        default:
            throw NetworkManagerError.unsupportedDriver(effectiveDriver)
        }
    }

    /// Delete a network
    public func deleteNetwork(id: String) async throws {
        // Look up driver from central mapping
        guard let driver = networkDrivers[id] else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Get metadata to check if it's a default network
        guard let metadata = await getNetwork(id: id) else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Prevent deletion of default networks
        if metadata.isDefault {
            throw NetworkManagerError.cannotDeleteDefault(metadata.name)
        }

        // Get network name for cleanup
        let networkName = metadata.name

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge", "wireguard":
            // Bridge networks always use WireGuard backend
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.backendNotReady
            }
            try await backend.deleteBridgeNetwork(id: id)

        case "vmnet":
            // Explicitly requested vmnet driver
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            try await backend.deleteBridgeNetwork(id: id)

        case "null":
            // "null" driver - just remove from StateStore
            try await stateStore.deleteNetwork(id: id)
            logger.info("Deleted null network", metadata: ["id": "\(id)"])

        default:
            throw NetworkManagerError.unsupportedDriver(driver)
        }

        // Remove from mappings after successful deletion
        networkDrivers.removeValue(forKey: id)
        networkNames.removeValue(forKey: networkName)
    }

    // MARK: - Container Attachment

    /// Attach container to network
    public func attachContainerToNetwork(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String,
        containerName: String,
        aliases: [String] = [],
        userSpecifiedIP: String? = nil,
        extraHosts: [String] = []
    ) async throws -> NetworkAttachment {
        // Look up driver from central mapping
        guard let driver = networkDrivers[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge", "wireguard":
            // Bridge networks always use WireGuard backend
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.backendNotReady
            }
            return try await backend.attachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID,
                containerName: containerName,
                aliases: aliases,
                userSpecifiedIP: userSpecifiedIP,
                extraHosts: extraHosts
            )

        case "vmnet":
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            // vmnet backend doesn't support user-specified IPs or dynamic attach
            if userSpecifiedIP != nil {
                throw NetworkManagerError.unsupportedFeature("vmnet backend does not support user-specified IPs")
            }
            // vmnet backend doesn't support dynamic attach
            try await backend.attachContainer(
                containerID: containerID,
                networkID: networkID,
                ipAddress: "",  // Not used (will throw error)
                gateway: ""     // Not used (will throw error)
            )
            fatalError("vmnet backend should have thrown dynamicAttachNotSupported")

        case "null":
            // "null" driver - no network interface attached
            // Return empty attachment (container only has loopback)
            logger.info("Skipping network attachment for null network", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
            return NetworkAttachment(
                networkID: networkID,
                ip: "",
                mac: "",
                aliases: []
            )

        default:
            throw NetworkManagerError.unsupportedDriver(driver)
        }
    }

    /// Detach container from network
    public func detachContainerFromNetwork(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String
    ) async throws {
        // Look up driver from central mapping
        guard let driver = networkDrivers[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Route to appropriate backend based on driver
        switch driver {
        case "null":
            // "null" driver - nothing to detach
            logger.info("Skipping network detachment for null network", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
            return
        case "bridge", "wireguard":
            // Bridge networks always use WireGuard backend
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.backendNotReady
            }
            try await backend.detachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID
            )

        case "vmnet":
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            try await backend.detachContainer(containerID: containerID, networkID: networkID)

        default:
            throw NetworkManagerError.unsupportedDriver(driver)
        }
    }

    /// Get vmnet interface for container (vmnet backend only, called during container creation)
    public func getVmnetInterfaceForContainer(containerID: String, networkID: String) async throws -> Any? {
        guard let backend = vmnetBackend else {
            return nil  // Not using vmnet backend
        }

        guard await backend.getNetwork(id: networkID) != nil else {
            return nil  // Network not found in vmnet backend
        }

        return try await backend.getInterfaceForContainer(containerID: containerID, networkID: networkID)
    }

    // MARK: - Network Queries

    /// Get network by ID
    public func getNetwork(id: String) async -> NetworkMetadata? {
        // Look up driver from central mapping
        guard let driver = networkDrivers[id] else {
            return nil
        }

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge", "wireguard":
            return try? await wireGuardBackend?.getNetwork(id: id)

        case "vmnet":
            return await vmnetBackend?.getNetwork(id: id)

        case "null":
            // "null" driver - load from StateStore
            //
            // Still returns nil on a failure, unlike listNetworks(): this
            // answers about one named network, and every caller already treats
            // nil as "not found". listNetworks() answers about the whole host,
            // where the same nil becomes a short list reported as success, so it
            // reads NullDriverNetworks directly rather than looping through here.
            do {
                guard let network = try await stateStore.loadAllNetworks()
                    .first(where: { $0.id == id }) else {
                    return nil
                }
                return NetworkMetadata(persisted: network)
            } catch {
                logger.error("Failed to load null network", metadata: ["id": "\(id)", "error": "\(error)"])
                return nil
            }

        default:
            return nil
        }
    }

    /// Get network by name
    public func getNetworkByName(name: String) async -> NetworkMetadata? {
        // Look up ID from name mapping, then use efficient getNetwork by ID
        guard let id = networkNames[name] else {
            return nil
        }

        return await getNetwork(id: id)
    }

    /// Get container attachments for a network
    ///
    /// Throws rather than returning `[:]`, which is indistinguishable from
    /// "nothing attached". This is the gate `docker network prune` reads to
    /// skip networks with active containers: swallowed with `try?`, a transient
    /// store failure on the attachment read -- while `listNetworks()` still
    /// succeeded -- made every network look unused and prune **deleted an
    /// in-use network** and reported success. Task 3 closed the total-failure
    /// case by making `listNetworks()` throw; the partial failure is what is
    /// left, and it is the harder one to notice.
    ///
    /// vmnet is asked first, and only for a network vmnet owns. Under the old
    /// order the WireGuard branch answered first and its `[:]` for a vmnet
    /// network counted as an answer, so the vmnet branch was unreachable
    /// whenever the backend was up -- which is always, after `initialize()`.
    /// Routing on which backend owns the network is what `deleteNetwork(id:)`
    /// already does.
    public func getNetworkAttachments(networkID: String) async throws -> [String: NetworkAttachment] {
        // vmnet keeps its attachments in memory, not in the StateStore.
        if let backend = vmnetBackend, await backend.getNetwork(id: networkID) != nil {
            return await backend.getNetworkAttachments(networkID: networkID)
        }

        return try await attachmentSource.getNetworkAttachments(networkID: networkID)
    }

    /// List all networks
    ///
    /// Throws rather than returning a short list. A WireGuard-backend failure
    /// swallowed by `try?` turns a real failure into a confident report of a
    /// clean host, which is the report that hides a leak. gascan maps a thrown
    /// failure to `command_io`; it has no way to see a silently short list.
    public func listNetworks() async throws -> [NetworkMetadata] {
        var networks: [NetworkMetadata] = []

        if let backend = vmnetBackend {
            networks.append(contentsOf: await backend.listNetworks())
        }

        for lister in networkListers {
            networks.append(contentsOf: try await lister.listNetworks())
        }

        return networks
    }

    /// Get networks for a container
    ///
    /// Throws for the same reason `getNetworkAttachments` does, one table over.
    /// Swallowed with `try?`, a store failure here read to `getWireGuardClient`
    /// as "this container is on no WireGuard network", and the caller that acts
    /// on that answer skips publishing the container's port mappings -- a
    /// container that comes up with its ports silently unmapped.
    ///
    /// vmnet is not consulted: it does not track container networks separately,
    /// as the branch this replaced recorded by doing nothing.
    public func getContainerNetworks(containerID: String) async throws -> [NetworkMetadata] {
        return try await attachmentSource.getContainerNetworks(containerID: containerID)
    }

    /// Resolve network ID from short ID or name
    ///
    /// Throws for the same reason `listNetworks()` does: the prefix match below
    /// is a listing, and a swallowed backend failure here would report "no such
    /// network" for a network that exists.
    public func resolveNetworkID(_ idOrName: String) async throws -> String? {
        // Try exact name match first
        if let network = await getNetworkByName(name: idOrName) {
            return network.id
        }

        // Try exact ID match
        if let network = await getNetwork(id: idOrName) {
            return network.id
        }

        // Try prefix match
        let allNetworks = try await listNetworks()
        let matches = allNetworks.filter { $0.id.hasPrefix(idOrName) }

        if matches.count == 1 {
            return matches[0].id
        } else if matches.count > 1 {
            // Ambiguous - return nil
            return nil
        }

        return nil
    }

    /// Get network name by ID
    public func getNetworkName(networkID: String) async -> String? {
        return await getNetwork(id: networkID)?.name
    }

    /// Create a WireGuard client for a container (for port mapping)
    /// Returns nil if container is not attached to any WireGuard networks or container not found
    /// Caller must disconnect the client when done
    ///
    /// Throws when the attachment read fails. `nil` here means "no client is
    /// wanted" and the caller publishes no ports on the strength of it, so a
    /// failure that cannot say whether the container is attached must not
    /// arrive as `nil`.
    public func getWireGuardClient(containerID: String) async throws -> WireGuardClient? {
        guard wireGuardBackend != nil else {
            return nil
        }

        // Get container networks - if not attached to any WireGuard networks, return nil
        let networks = try await getContainerNetworks(containerID: containerID)
        guard !networks.isEmpty else {
            return nil
        }

        // Get native container object
        guard let container = await containerManager.getNativeContainer(id: containerID) else {
            return nil
        }

        // Create client
        let client = WireGuardClient(logger: logger)
        do {
            try await client.connect(container: container, vsockPort: 51820)
            return client
        } catch {
            logger.error("Failed to create WireGuard client for port mapping", metadata: [
                "container_id": "\(containerID)",
                "error": "\(error)"
            ])
            return nil
        }
    }

    /// Clean up in-memory network state for a stopped/exited container
    /// Called when container stops to ensure state is clean for restart
    public func cleanupStoppedContainer(containerID: String) async {
        // Clean up in all backends (container could be in any)
        if let backend = vmnetBackend {
            await backend.cleanupStoppedContainer(containerID: containerID)
        }

        if let backend = wireGuardBackend {
            await backend.cleanupStoppedContainer(containerID: containerID)
        }
    }

    // MARK: - Helper Methods

    /// Generate a Docker-compatible network ID (64-char hex)
    private func generateNetworkID() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Duplicate to get 64 chars
        return uuid + uuid
    }
}

// MARK: - Errors

public enum NetworkManagerError: Error, CustomStringConvertible {
    case invalidName(String)
    case nameExists(String)
    case networkNotFound(String)
    case ambiguousID(String, Int)
    case unsupportedDriver(String)
    case hasActiveEndpoints(String, Int)
    case cannotDeleteDefault(String)
    case alreadyConnected(String, String)
    case notConnected(String, String)
    case ipAllocationFailed(String)
    case backendNotReady
    case containerNotFound(String)
    case dynamicAttachNotSupported(backend: String, suggestion: String)
    case invalidIPAddress(String)
    case ipAlreadyInUse(String)
    case unsupportedFeature(String)
    case noAvailableSubnets

    public var description: String {
        switch self {
        case .invalidName(let reason):
            return "Invalid network name: \(reason)"
        case .nameExists(let name):
            return "network with name \(name) already exists"
        case .networkNotFound(let id):
            return "network \(id) not found"
        case .ambiguousID(let id, let count):
            return "multiple IDs found with prefix '\(id)': \(count) IDs matched"
        case .unsupportedDriver(let driver):
            return "network driver \(driver) not supported"
        case .hasActiveEndpoints(let name, let count):
            return "network \(name) has active endpoints (\(count) containers connected)"
        case .cannotDeleteDefault(let name):
            return "cannot remove default network '\(name)'"
        case .alreadyConnected(let containerID, let networkName):
            return "container \(containerID) is already connected to network \(networkName)"
        case .notConnected(let containerID, let networkName):
            return "container \(containerID) is not connected to network \(networkName)"
        case .ipAllocationFailed(let reason):
            return "IP allocation failed: \(reason)"
        case .backendNotReady:
            return "Network backend is not ready"
        case .containerNotFound(let id):
            return "Container not found: \(id)"
        case .dynamicAttachNotSupported(let backend, let suggestion):
            return "\(backend) backend does not support 'docker network connect' after container creation.\n\(suggestion)"
        case .invalidIPAddress(let message):
            return "Invalid IP address: \(message)"
        case .ipAlreadyInUse(let ip):
            return "IP address \(ip) is already in use"
        case .unsupportedFeature(let message):
            return "Unsupported feature: \(message)"
        case .noAvailableSubnets:
            return "No available subnets in range 172.18.0.0/16 - 172.31.0.0/16 (all 14 subnets in use)"
        }
    }
}
