import Foundation
import ContainerBridge

/// Handlers for Docker Engine API system endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md
public struct SystemHandlers: Sendable {
    private let containerManager: ContainerManager
    private let imageManager: ImageManager

    public init(containerManager: ContainerManager, imageManager: ImageManager) {
        self.containerManager = containerManager
        self.imageManager = imageManager
    }

    /// Handle GET /_ping
    /// Returns: "OK" with 200 status
    public static func handlePing() -> PingResponse {
        // Containers run Linux, not darwin (even though Arca runs on macOS)
        return PingResponse(apiVersion: ArcaVersion.apiVersion, osType: "linux")
    }

    /// Handle GET /version
    /// Returns: Version information about the Docker Engine API
    public static func handleVersion() -> VersionResponse {
        let arch = ProcessInfo.processInfo.machineArchitecture
        let kernelVersion = ProcessInfo.processInfo.kernelVersion
        let goVersion = "swift\(ArcaVersion.swiftVersion)"

        // Build engine component with details
        let engineDetails = ComponentDetails(
            apiVersion: ArcaVersion.apiVersion,
            arch: arch,
            buildTime: ArcaVersion.buildTime,
            experimental: ArcaVersion.experimental ? "true" : "false",
            gitCommit: ArcaVersion.gitCommit,
            goVersion: goVersion,
            kernelVersion: kernelVersion,
            minAPIVersion: ArcaVersion.minAPIVersion,
            os: "linux"
        )

        let engineComponent = VersionComponent(
            name: "Engine",
            version: ArcaVersion.version,
            details: engineDetails
        )

        return VersionResponse(
            platform: VersionPlatform(name: "Arca Container Runtime"),
            components: [engineComponent],
            version: ArcaVersion.version,
            apiVersion: ArcaVersion.apiVersion,
            minAPIVersion: ArcaVersion.minAPIVersion,
            gitCommit: ArcaVersion.gitCommit,
            goVersion: goVersion,
            os: "linux",  // Containers run Linux, not darwin
            arch: arch,
            kernelVersion: kernelVersion,
            experimental: ArcaVersion.experimental,
            buildTime: ArcaVersion.buildTime
        )
    }

    /// Handle GET /info
    /// Returns: System information about the Docker daemon
    public func handleInfo() async -> SystemInfoResponse {
        let processInfo = ProcessInfo.processInfo

        // Get actual container counts
        let containers = (try? await containerManager.listContainers(all: true, filters: [:], includeInternal: false)) ?? []
        let totalContainers = containers.count
        let runningContainers = containers.filter { $0.state == "running" }.count
        let pausedContainers = containers.filter { $0.state == "paused" }.count
        let stoppedContainers = containers.filter { $0.state != "running" && $0.state != "paused" }.count

        // Get actual image count
        let images = (try? await imageManager.listImages(filters: [:])) ?? []
        let totalImages = images.count

        // Generate a unique daemon ID (use hostname-based ID for consistency)
        let daemonID = Self.generateDaemonID()

        return SystemInfoResponse(
            id: daemonID,
            containers: totalContainers,
            containersRunning: runningContainers,
            containersPaused: pausedContainers,
            containersStopped: stoppedContainers,
            images: totalImages,
            driver: "arca",
            dockerRootDir: NSString(string: "~/.arca").expandingTildeInPath,
            memoryLimit: true,
            swapLimit: true,
            cpuCfsPeriod: true,
            cpuCfsQuota: true,
            cpuShares: true,
            cpuSet: true,
            pidsLimit: true,
            oomKillDisable: true,
            ipv4Forwarding: true,
            debug: false,
            systemTime: ISO8601DateFormatter().string(from: Date()),
            loggingDriver: "json-file",
            cgroupDriver: "cgroupfs",
            cgroupVersion: "2",
            kernelVersion: processInfo.kernelVersion,
            operatingSystem: "Arca Container Runtime",
            osVersion: ArcaVersion.version,
            osType: "linux",
            architecture: processInfo.machineArchitecture,
            ncpu: processInfo.activeProcessorCount,
            memTotal: Int64(processInfo.physicalMemory),
            name: processInfo.hostName,
            experimentalBuild: ArcaVersion.experimental,
            serverVersion: ArcaVersion.version
        )
    }

    /// Generate a consistent daemon ID based on hostname
    private static func generateDaemonID() -> String {
        let hostname = ProcessInfo.processInfo.hostName
        // Create a consistent 12-segment ID like Docker does
        let hash = hostname.hashValue
        let segments = (0..<12).map { i in
            let value = (hash + i * 7919) & 0xFFFF
            return String(format: "%04X", value)
        }
        return segments.joined(separator: ":")
    }
}

// MARK: - Response Models

/// Response for /_ping endpoint
public struct PingResponse: Codable {
    public let apiVersion: String
    public let osType: String

    enum CodingKeys: String, CodingKey {
        case apiVersion = "API-Version"
        case osType = "OSType"
    }

    public init(apiVersion: String, osType: String) {
        self.apiVersion = apiVersion
        self.osType = osType
    }
}

/// Platform information for version response
public struct VersionPlatform: Codable {
    public let name: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }

    public init(name: String) {
        self.name = name
    }
}

/// Component details for version response
public struct ComponentDetails: Codable {
    public let apiVersion: String
    public let arch: String
    public let buildTime: String
    public let experimental: String
    public let gitCommit: String
    public let goVersion: String
    public let kernelVersion: String
    public let minAPIVersion: String
    public let os: String

    enum CodingKeys: String, CodingKey {
        case apiVersion = "ApiVersion"
        case arch = "Arch"
        case buildTime = "BuildTime"
        case experimental = "Experimental"
        case gitCommit = "GitCommit"
        case goVersion = "GoVersion"
        case kernelVersion = "KernelVersion"
        case minAPIVersion = "MinAPIVersion"
        case os = "Os"
    }

    public init(
        apiVersion: String,
        arch: String,
        buildTime: String,
        experimental: String,
        gitCommit: String,
        goVersion: String,
        kernelVersion: String,
        minAPIVersion: String,
        os: String
    ) {
        self.apiVersion = apiVersion
        self.arch = arch
        self.buildTime = buildTime
        self.experimental = experimental
        self.gitCommit = gitCommit
        self.goVersion = goVersion
        self.kernelVersion = kernelVersion
        self.minAPIVersion = minAPIVersion
        self.os = os
    }
}

/// Component in version response
public struct VersionComponent: Codable {
    public let name: String
    public let version: String
    public let details: ComponentDetails?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case version = "Version"
        case details = "Details"
    }

    public init(name: String, version: String, details: ComponentDetails? = nil) {
        self.name = name
        self.version = version
        self.details = details
    }
}

/// Response for /version endpoint
/// Based on Docker Engine API v1.51 specification
public struct VersionResponse: Codable {
    public let platform: VersionPlatform
    public let components: [VersionComponent]
    public let version: String
    public let apiVersion: String
    public let minAPIVersion: String
    public let gitCommit: String
    public let goVersion: String
    public let os: String
    public let arch: String
    public let kernelVersion: String
    public let experimental: Bool
    public let buildTime: String

    enum CodingKeys: String, CodingKey {
        case platform = "Platform"
        case components = "Components"
        case version = "Version"
        case apiVersion = "ApiVersion"
        case minAPIVersion = "MinAPIVersion"
        case gitCommit = "GitCommit"
        case goVersion = "GoVersion"
        case os = "Os"
        case arch = "Arch"
        case kernelVersion = "KernelVersion"
        case experimental = "Experimental"
        case buildTime = "BuildTime"
    }

    public init(
        platform: VersionPlatform,
        components: [VersionComponent],
        version: String,
        apiVersion: String,
        minAPIVersion: String,
        gitCommit: String,
        goVersion: String,
        os: String,
        arch: String,
        kernelVersion: String,
        experimental: Bool,
        buildTime: String
    ) {
        self.platform = platform
        self.components = components
        self.version = version
        self.apiVersion = apiVersion
        self.minAPIVersion = minAPIVersion
        self.gitCommit = gitCommit
        self.goVersion = goVersion
        self.os = os
        self.arch = arch
        self.kernelVersion = kernelVersion
        self.experimental = experimental
        self.buildTime = buildTime
    }
}

/// Response for /info endpoint
/// Based on Docker Engine API v1.51 specification - SystemInfo definition
public struct SystemInfoResponse: Codable {
    public let id: String
    public let containers: Int
    public let containersRunning: Int
    public let containersPaused: Int
    public let containersStopped: Int
    public let images: Int
    public let driver: String
    public let dockerRootDir: String
    public let memoryLimit: Bool
    public let swapLimit: Bool
    public let cpuCfsPeriod: Bool
    public let cpuCfsQuota: Bool
    public let cpuShares: Bool
    public let cpuSet: Bool
    public let pidsLimit: Bool
    public let oomKillDisable: Bool
    public let ipv4Forwarding: Bool
    public let debug: Bool
    public let systemTime: String
    public let loggingDriver: String
    public let cgroupDriver: String
    public let cgroupVersion: String
    public let kernelVersion: String
    public let operatingSystem: String
    public let osVersion: String
    public let osType: String
    public let architecture: String
    public let ncpu: Int
    public let memTotal: Int64
    public let name: String
    public let experimentalBuild: Bool
    public let serverVersion: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case containers = "Containers"
        case containersRunning = "ContainersRunning"
        case containersPaused = "ContainersPaused"
        case containersStopped = "ContainersStopped"
        case images = "Images"
        case driver = "Driver"
        case dockerRootDir = "DockerRootDir"
        case memoryLimit = "MemoryLimit"
        case swapLimit = "SwapLimit"
        case cpuCfsPeriod = "CpuCfsPeriod"
        case cpuCfsQuota = "CpuCfsQuota"
        case cpuShares = "CPUShares"
        case cpuSet = "CPUSet"
        case pidsLimit = "PidsLimit"
        case oomKillDisable = "OomKillDisable"
        case ipv4Forwarding = "IPv4Forwarding"
        case debug = "Debug"
        case systemTime = "SystemTime"
        case loggingDriver = "LoggingDriver"
        case cgroupDriver = "CgroupDriver"
        case cgroupVersion = "CgroupVersion"
        case kernelVersion = "KernelVersion"
        case operatingSystem = "OperatingSystem"
        case osVersion = "OSVersion"
        case osType = "OSType"
        case architecture = "Architecture"
        case ncpu = "NCPU"
        case memTotal = "MemTotal"
        case name = "Name"
        case experimentalBuild = "ExperimentalBuild"
        case serverVersion = "ServerVersion"
    }

    public init(
        id: String,
        containers: Int,
        containersRunning: Int,
        containersPaused: Int,
        containersStopped: Int,
        images: Int,
        driver: String,
        dockerRootDir: String,
        memoryLimit: Bool,
        swapLimit: Bool,
        cpuCfsPeriod: Bool,
        cpuCfsQuota: Bool,
        cpuShares: Bool,
        cpuSet: Bool,
        pidsLimit: Bool,
        oomKillDisable: Bool,
        ipv4Forwarding: Bool,
        debug: Bool,
        systemTime: String,
        loggingDriver: String,
        cgroupDriver: String,
        cgroupVersion: String,
        kernelVersion: String,
        operatingSystem: String,
        osVersion: String,
        osType: String,
        architecture: String,
        ncpu: Int,
        memTotal: Int64,
        name: String,
        experimentalBuild: Bool,
        serverVersion: String
    ) {
        self.id = id
        self.containers = containers
        self.containersRunning = containersRunning
        self.containersPaused = containersPaused
        self.containersStopped = containersStopped
        self.images = images
        self.driver = driver
        self.dockerRootDir = dockerRootDir
        self.memoryLimit = memoryLimit
        self.swapLimit = swapLimit
        self.cpuCfsPeriod = cpuCfsPeriod
        self.cpuCfsQuota = cpuCfsQuota
        self.cpuShares = cpuShares
        self.cpuSet = cpuSet
        self.pidsLimit = pidsLimit
        self.oomKillDisable = oomKillDisable
        self.ipv4Forwarding = ipv4Forwarding
        self.debug = debug
        self.systemTime = systemTime
        self.loggingDriver = loggingDriver
        self.cgroupDriver = cgroupDriver
        self.cgroupVersion = cgroupVersion
        self.kernelVersion = kernelVersion
        self.operatingSystem = operatingSystem
        self.osVersion = osVersion
        self.osType = osType
        self.architecture = architecture
        self.ncpu = ncpu
        self.memTotal = memTotal
        self.name = name
        self.experimentalBuild = experimentalBuild
        self.serverVersion = serverVersion
    }
}

// MARK: - ProcessInfo Extensions

extension ProcessInfo {
    /// Get the machine architecture (arm64, x86_64, etc.)
    var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Get the kernel version
    var kernelVersion: String {
        var sysinfo = utsname()
        uname(&sysinfo)

        let release = withUnsafePointer(to: &sysinfo.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }

        return release
    }
}
