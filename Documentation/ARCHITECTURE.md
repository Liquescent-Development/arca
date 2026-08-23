# Arca Architecture

This document describes the internal architecture of Arca, a Docker Engine API implementation backed by Apple's Containerization framework.

## System Overview

```mermaid
graph TB
    subgraph "Docker Ecosystem"
        CLI[Docker CLI]
        Compose[Docker Compose]
        Buildx[Docker Buildx]
    end

    subgraph "Arca Daemon"
        Socket[Unix Socket<br/>/var/run/arca.sock]
        Server[SwiftNIO Server<br/>ArcaDaemon]
        Router[Router +<br/>Middleware]

        subgraph "Handlers"
            ContainerH[Container<br/>Handlers]
            ImageH[Image<br/>Handlers]
            NetworkH[Network<br/>Handlers]
            VolumeH[Volume<br/>Handlers]
            ExecH[Exec<br/>Handlers]
        end

        subgraph "ContainerBridge"
            CM[Container<br/>Manager]
            IM[Image<br/>Manager]
            NM[Network<br/>Manager]
            VM[Volume<br/>Manager]
            EM[Exec<br/>Manager]
            SS[StateStore<br/>SQLite]
        end
    end

    subgraph "Apple Framework"
        ACF[Apple Containerization<br/>Framework]
        VMs[Linux VMs<br/>Containers]
    end

    CLI --> Socket
    Compose --> Socket
    Buildx --> Socket
    Socket --> Server
    Server --> Router
    Router --> ContainerH
    Router --> ImageH
    Router --> NetworkH
    Router --> VolumeH
    Router --> ExecH

    ContainerH --> CM
    ImageH --> IM
    NetworkH --> NM
    VolumeH --> VM
    ExecH --> EM

    CM --> ACF
    IM --> ACF
    NM --> ACF
    VM --> ACF
    EM --> ACF
    CM --> SS
    VM --> SS

    ACF --> VMs

    style Socket fill:#e1f5ff
    style Server fill:#fff4e1
    style ACF fill:#ffe1e1
    style VMs fill:#ffe1e1
    style SS fill:#e1ffe1
```

## Module Structure

```mermaid
graph LR
    subgraph "Arca (Executable)"
        Main[main.swift<br/>CLI Entry Point]
    end

    subgraph "ArcaDaemon"
        Server[Server.swift<br/>SwiftNIO]
        Router[Router.swift<br/>Request Routing]
        HTTP[HTTPHandler.swift<br/>HTTP Processing]
        MW1[RequestLogger<br/>Middleware]
        MW2[APIVersionNormalizer<br/>Middleware]
    end

    subgraph "DockerAPI"
        Models[Models/<br/>Container, Image, etc.]
        Handlers[Handlers/<br/>ContainerHandlers, etc.]
    end

    subgraph "ContainerBridge"
        Managers[Managers/<br/>Container, Image, Network, etc.]
        Backends[Network Backends/<br/>WireGuard, Vmnet]
        Rootfs[ImageRootfsUnpacker<br/>One composed ext4 per image]
        Generated[Generated/<br/>gRPC Clients]
    end

    Main --> Server
    Server --> Router
    Router --> MW1
    Router --> MW2
    Router --> Handlers
    Handlers --> Managers
    Managers --> Backends
    Managers --> Rootfs
    Managers --> Generated

    style Main fill:#e1f5ff
    style Server fill:#fff4e1
    style Handlers fill:#ffe1ff
    style Managers fill:#e1ffe1
```

## Request Flow

```mermaid
sequenceDiagram
    participant CLI as Docker CLI
    participant Socket as Unix Socket
    participant Server as SwiftNIO Server
    participant Router as Router
    participant Middleware as Middleware Pipeline
    participant Handler as ContainerHandlers
    participant Manager as ContainerManager
    participant Apple as Apple Containerization
    participant VM as Linux VM

    CLI->>Socket: POST /v1.51/containers/create
    Socket->>Server: HTTP Request
    Server->>Router: Parse & Route
    Router->>Middleware: /v1.51/containers/create
    Middleware->>Middleware: Strip version prefix
    Middleware->>Handler: /containers/create
    Handler->>Manager: createContainer()
    Manager->>Apple: Create VM
    Apple->>VM: Start Linux VM
    VM-->>Apple: VM Running
    Apple-->>Manager: Container UUID
    Manager->>Manager: Generate Docker ID<br/>Store ID mapping
    Manager-->>Handler: Container created
    Handler-->>Middleware: JSON Response
    Middleware->>Middleware: Log response
    Middleware-->>Router: Response
    Router-->>Server: Response
    Server-->>Socket: HTTP 201 Created
    Socket-->>CLI: {"Id": "abc123..."}
```

## Networking Architecture

```mermaid
graph TB
    subgraph "Arca Daemon"
        NM[NetworkManager<br/>Facade]
        WGB[WireGuardNetworkBackend<br/>Default Driver]
        VNB[VmnetNetworkBackend<br/>Optional Driver]
        WGC[WireGuardClient<br/>gRPC Client]
        IPAM[IPAMAllocator<br/>IP Management]
    end

    subgraph "Container A VM"
        WGA[arca-wireguard-service<br/>vsock:51820]
        WG1[WireGuard Interface<br/>wg0: 172.20.0.2]
        Eth1A[eth0 mapped to wg0]
    end

    subgraph "Container B VM"
        WGB2[arca-wireguard-service<br/>vsock:51820]
        WG2[WireGuard Interface<br/>wg0: 172.20.0.3]
        Eth1B[eth0 mapped to wg0]
    end

    subgraph "Container C VM"
        WGC2[arca-wireguard-service<br/>vsock:51820]
        WG3[WireGuard Interface<br/>wg0: 172.20.0.4]
        Eth1C[eth0 mapped to wg0]
    end

    NM --> WGB
    NM --> VNB
    WGB --> WGC
    WGB --> IPAM

    WGC -->|gRPC/vsock| WGA
    WGC -->|gRPC/vsock| WGB2
    WGC -->|gRPC/vsock| WGC2

    WGA --> WG1
    WGB2 --> WG2
    WGC2 --> WG3

    WG1 --> Eth1A
    WG2 --> Eth1B
    WG3 --> Eth1C

    WG1 -.->|Peer-to-Peer<br/>Encrypted Tunnel| WG2
    WG1 -.->|Peer-to-Peer<br/>Encrypted Tunnel| WG3
    WG2 -.->|Peer-to-Peer<br/>Encrypted Tunnel| WG3

    style NM fill:#e1f5ff
    style WGB fill:#e1ffe1
    style WGC fill:#fff4e1
    style WGA fill:#ffe1e1
    style WGB2 fill:#ffe1e1
    style WGC2 fill:#ffe1e1
```

### WireGuard Full Mesh Topology

Each container on a network has WireGuard peers to all other containers on that network:

```mermaid
graph LR
    A[Container A<br/>172.20.0.2]
    B[Container B<br/>172.20.0.3]
    C[Container C<br/>172.20.0.4]
    D[Container D<br/>172.20.0.5]

    A <-->|WireGuard Peer| B
    A <-->|WireGuard Peer| C
    A <-->|WireGuard Peer| D
    B <-->|WireGuard Peer| C
    B <-->|WireGuard Peer| D
    C <-->|WireGuard Peer| D

    style A fill:#e1f5ff
    style B fill:#ffe1ff
    style C fill:#e1ffe1
    style D fill:#fff4e1
```

## Volume Architecture

```mermaid
graph TB
    subgraph "Arca Daemon"
        VM[VolumeManager]
        SS[StateStore<br/>SQLite]
    end

    subgraph "Volume Storage ~/.arca/volumes/"
        LocalVol["mydata/<br/>├── data/<br/>│   └── files"]
        BlockVol["mydb/<br/>└── volume.img<br/>    (EXT4 filesystem)"]
    end

    subgraph "Container VM"
        subgraph "VirtioFS Shares"
            BindMount["/host-data<br/>macOS directory"]
            LocalMount["/app-data<br/>~/.arca/volumes/mydata/data"]
        end

        subgraph "Block Device"
            BlockMount["/var/lib/db<br/>EXT4 block device"]
        end
    end

    VM -->|Manages| LocalVol
    VM -->|Manages| BlockVol
    VM -->|Metadata| SS

    LocalVol -.->|VirtioFS| LocalMount
    BlockVol -.->|EXT4 Mount| BlockMount

    style VM fill:#e1f5ff
    style SS fill:#e1ffe1
    style LocalVol fill:#fff4e1
    style BlockVol fill:#ffe1ff
    style BindMount fill:#e1ffe1
    style LocalMount fill:#fff4e1
    style BlockMount fill:#ffe1ff
```

### Volume Driver Comparison

| Feature | Local Driver (Default) | Block Driver (Optional) |
|---------|----------------------|------------------------|
| **Storage** | VirtioFS directory | EXT4 block device |
| **Location** | `~/.arca/volumes/{name}/data/` | `~/.arca/volumes/{name}/volume.img` |
| **Sharing** | ✅ Multiple containers | ❌ Exclusive access |
| **Use Case** | General purpose | Databases, high I/O |
| **Performance** | Good | Better for heavy I/O |
| **Creation** | `docker volume create mydata` | `docker volume create --driver block mydata` |

## Container Persistence

```mermaid
stateDiagram-v2
    [*] --> Created: docker create
    Created --> Running: docker start
    Running --> Paused: docker pause
    Paused --> Running: docker unpause
    Running --> Stopped: docker stop
    Running --> Exited: Process exits
    Stopped --> Running: docker start
    Exited --> Running: docker start<br/>(if restart policy)
    Stopped --> Removed: docker rm
    Exited --> Removed: docker rm
    Created --> Removed: docker rm
    Removed --> [*]

    note right of Created
        State persisted to SQLite:
        - Container config
        - Network attachments
        - Volume mounts
        - Restart policy
    end note

    note right of Running
        Monitoring goroutine:
        - Waits for exit
        - Records exit code
        - Updates database
        - Handles restart policy
    end note

    note right of Exited
        Daemon restart:
        - VM destroyed (ephemeral)
        - State in SQLite survives
        - docker start recreates VM
    end note
```

### Restart Policy Behavior

```mermaid
graph TD
    Exit[Container Exits]

    Exit --> CheckPolicy{Restart<br/>Policy?}

    CheckPolicy -->|no| StayExited[Stays Exited]
    CheckPolicy -->|always| Restart1[Always Restart]
    CheckPolicy -->|unless-stopped| CheckStopped{Explicitly<br/>stopped?}
    CheckPolicy -->|on-failure| CheckCode{Exit<br/>code?}

    CheckStopped -->|Yes| StayExited
    CheckStopped -->|No| Restart2[Restart]

    CheckCode -->|0| StayExited
    CheckCode -->|non-zero| Restart3[Restart]

    Restart1 --> Running[Back to Running]
    Restart2 --> Running
    Restart3 --> Running

    style Exit fill:#ffe1e1
    style Running fill:#e1ffe1
    style StayExited fill:#e1f5ff
```

## Image Management

```mermaid
graph TB
    subgraph "Image Pull Flow"
        CLI[docker pull nginx]
        IM[ImageManager]
        Registry[Docker Hub<br/>registry-1.docker.io]

        CLI --> IM
        IM -->|1. Fetch manifest| Registry
        Registry -->|2. Manifest JSON| IM
        IM -->|3. Parse layers| IM
        IM -->|4. Download blobs<br/>Up to 8 parallel| Registry
        Registry -->|5. Layer data| IM
        IM -->|6. Store in OCI layout| Storage
    end

    subgraph "OCI Image Layout ~/.arca/images/"
        Storage[blobs/<br/>├── sha256/<br/>│   ├── abc123...<br/>│   ├── def456...<br/>│   └── ...]
        Index[index.json]
        Manifests[manifests/<br/>└── nginx/latest]
    end

    IM -.->|Progress events| Progress[Docker CLI<br/>Progress bars]

    Storage --> Index
    Index --> Manifests

    style CLI fill:#e1f5ff
    style IM fill:#fff4e1
    style Registry fill:#ffe1ff
    style Storage fill:#e1ffe1
```

### Image Progress Reporting

```mermaid
sequenceDiagram
    participant IM as ImageManager
    participant Apple as Apple Framework
    participant CLI as Docker CLI

    Note over IM: Parse manifest,<br/>get layer digests

    IM->>CLI: Layer abc123: Pulling fs layer
    IM->>CLI: Layer def456: Pulling fs layer
    IM->>CLI: Layer ghi789: Pulling fs layer

    Apple->>IM: add-size: 1024 bytes
    Note over IM: Distribute progress<br/>proportionally by size
    IM->>CLI: Layer abc123: Downloading [=>   ] 512B/2KB
    IM->>CLI: Layer def456: Downloading [>    ] 256B/4KB

    Apple->>IM: add-items: 1
    Note over IM: Estimate completion<br/>by size ratios
    IM->>CLI: Layer abc123: Pull complete

    Apple->>IM: add-size: 2048 bytes
    IM->>CLI: Layer def456: Downloading [===> ] 2KB/4KB

    Apple->>IM: add-items: 1
    IM->>CLI: Layer def456: Pull complete

    Note over IM,CLI: Aggregate progress accurate,<br/>per-layer progress estimated
```

### Container Root Filesystem

A pulled image is stored as layers, but a container never sees them as separate
devices. **The host composes every layer of an image into one ext4 filesystem and
attaches that single block device**, plus one writable layer for the container.
The image therefore contributes exactly one block device whatever its layer count
— the same for a one-layer image and a thirty-five-layer one.

```
<state-root>/image-rootfs/<image-digest>/<os>-<arch>/rootfs.ext4   shared, one per image+platform
<image-store>/containers/<container-id>/writable.ext4              private, one per container
```

`<image-digest>` has its `:` rewritten to `-`, so the directory is
`sha256-<hex>` and not `sha256:<hex>` — `rootfsPath(forImageDigest:platform:)` does
that rewrite, and a reader looking for the literal digest on disk will not find it.

`ImageRootfsUnpacker` (`Sources/ContainerBridge/ImageRootfsUnpacker.swift`) owns
the first of those. The second is `ContainerManager.writableLayer(at:sizeInBytes:)`.
Upstream's `LinuxContainer` stacks them inside the guest — the image rootfs as the
overlay's lower layer, the writable layer as its upper — so a container's writes
land in its own file rather than the shared one.

That last property is a consequence of always passing a writable layer, not
something the shared file enforces. Upstream strips `"ro"` from the rootfs mount
before attaching it, so the device reaches the guest writable; a caller that passed
no writable layer would get the shared slot mounted read-write.
`ImageRootfsUnpacker.blockMount(at:)` records the mechanism and what stays open.

The cache is keyed on **image digest plus `os` and `architecture`**, not on the digest
alone: a multi-platform image has one index digest and a different layer set per
platform, so a digest-only key would hand an arm64 rootfs to an amd64 request. The key
does **not** include the platform `variant`, so `linux/arm/v6` and `linux/arm/v7` would
share a slot -- unreachable while `detectSystemPlatform()` emits no variant, and a thing
to fix before arca honours `--platform`.

Two properties of that cache are load-bearing and are worth knowing before
changing it:

- **The slot is created only by a promotion.** The unpack writes to a sibling
  staging path and is `rename(2)`d onto the slot only after it is verified. An
  unpack that fails leaves no slot for a later create to mistake for a cache hit.
  `Documentation/EVIDENCE-layer-cache-poisoning.md` records why, with the
  measurements.
- **A second container from the same image skips the unpack.** That is the benefit
  the earlier per-layer cache bought, and keying the slot per image rather than per
  container is what preserves it.

**Historical note.** Arca previously ran a fork-local design that unpacked each
layer into its own ext4 and attached one block device per layer, composing the
overlay inside the guest at boot. It capped images at roughly 24 layers, because
the engine allocates block device tags from a 26-letter alphabet, and that ceiling
is why it was reverted to upstream's model.

The host side of it is gone from this repository, and so is the guest side. The
guest-side boot code went out with the submodule pointer bump — `b325bc5`, which moved
the pointer from `6304122` to `a5803b6` — removing 343 lines from
`vminitd/Sources/VminitdCore` (`ArcaBoot.swift`, `AgentCommand.swift`,
`Server+GRPC.swift`, per `git diff --numstat 6304122 a5803b6`). `ArcaBoot` retains only
`startServices(log:)`.

**That guest code has not been executed by anything, and the ceiling is NOT yet proven
gone.** All 343 removed lines sit inside `#if os(Linux)`, which macOS compiles none of,
and cross-compiling is unavailable on the development host (the installed Static Linux SDK
carries only an x86_64 slice). Nothing in this repository can settle it. It gets verified
by the 35-layer workspace image creating and running against a released engine, and by
that alone — never by a unit test asserting a device count. The test that used to make
that assertion was deleted for exactly this reason.

## Container Lifecycle Integration

```mermaid
graph TB
    subgraph "Arca ContainerManager"
        Create[createContainer]
        Start[startContainer]
        Monitor[Monitoring Goroutine]
        StateStore[(StateStore<br/>SQLite)]
    end

    subgraph "Apple Containerization Framework"
        ACF[Containerization API]
        VM[Linux VM<br/>Ephemeral]
    end

    subgraph "WireGuard Service"
        WGS[arca-wireguard-service<br/>vsock:51820]
        WG[WireGuard<br/>Interfaces]
    end

    Create -->|1. Save config| StateStore
    Create -->|2. Create VM| ACF
    ACF -->|3. VM object| VM

    Start -->|4. Configure network| WGS
    WGS -->|5. Setup WireGuard| WG
    Start -->|6. Start process| VM
    Start -->|7. Start monitoring| Monitor

    Monitor -->|Wait for exit| VM
    VM -->|Exit code| Monitor
    Monitor -->|8. Record exit| StateStore
    Monitor -->|9. Check restart policy| Monitor
    Monitor -.->|If restart| Start

    style StateStore fill:#e1ffe1
    style VM fill:#ffe1e1
    style Monitor fill:#fff4e1
```

## vminitd Custom Fork

```mermaid
graph TB
    subgraph "Arca Repository"
        Submodule[containerization/<br/>Git Submodule]
    end

    subgraph "arca-vminitd Fork"
        Upstream[Apple's upstream<br/>containerization repo]
        Extensions[vminitd/extensions/<br/>Arca-specific code]

        subgraph "Extensions"
            WG[wireguard-service/<br/>WireGuard management]
            FS[filesystem-service/<br/>guest filesystem RPCs<br/>see caveat below]
        end
    end

    subgraph "Built vminit:latest Image ~/.arca/vminit/"
        Binary["/sbin/vminitd<br/>PID 1 in containers"]
        WGBin["/usr/local/bin/<br/>arca-wireguard-service"]
        FSBin["/usr/local/bin/<br/>arca-filesystem-service"]
    end

    Submodule -.->|Points to| Upstream
    Submodule --> Extensions

    Extensions --> WG
    Extensions --> FS

    WG -->|Built into| WGBin
    FS -->|Built into| FSBin
    Upstream -->|Built into| Binary

    Binary -.->|Runs| WGBin
    Binary -.->|Runs| FSBin

    style Submodule fill:#e1f5ff
    style Extensions fill:#fff4e1
    style WG fill:#ffe1ff
    style FS fill:#ffe1ff
    style Binary fill:#e1ffe1
```

**Caveat on `filesystem-service`.** The binary is built and shipped and serves ten
RPCs — `Ready`, `SyncFilesystem`, `EnumerateUpperdir`, `ReadArchive`,
`WriteArchive`, `CreateBindMount`, `StatPath`, `CreateVolumeOverlay`,
`CreateDirectMount` and `GenerateHostsFile`, per the method descriptors in
`Sources/ContainerBridge/Generated/filesystem.grpc.swift`.
**Two of them are OverlayFS-based, and those two do not work** — and did not
work before the revert to a single composed rootfs either. They are broken in
different ways, not one way. Verified against
`git show a5803b6:vminitd/extensions/arca-services/internal/filesystem/filesystem.go`, the
pinned submodule object. The file is **byte-identical at `6304122` and `a5803b6`**
(`git diff --stat 6304122 a5803b6 --` over that path is empty), so the offsets below hold
at both pointers — the revert does not touch this Go tree:

- `EnumerateUpperdir`, which `docker diff` reaches, looks for `/mnt/vdb/upper`
  (`:151`) and answers `upperdir not found at /mnt/vdb/upper` (`:157`) when it is
  absent. The fork's guest-side overlay mounted at `/mnt/writable`, so that path
  never resolved.
- `CreateVolumeOverlay` has **no hand-written caller** — every reference to it under
  `Sources/` is in `Sources/ContainerBridge/Generated/` — so it is unreachable rather
  than observed failing. Its `/proc/mounts` scan for a literal `/dev/vdb` is in
  `findWritableMountPath()`, which `CreateDirectMount` also calls, so that scan is **not**
  evidence about this RPC specifically; unreachability is the whole of the evidence here.

The revert changes which way this subsystem is broken, not whether it is. Wiring
named volumes and `docker diff` onto the single composed rootfs is separate work.

**Also not done, and named here so it is an absence rather than an oversight:** nothing
evicts the per-image rootfs cache. `docker rmi` removes the image; its
`<root>/image-rootfs/sha256-<digest>/<os>-<arch>/rootfs.ext4` stays on disk indefinitely.
`ImageManager` never sees the cache path, and `LayerCacheReclaim` deletes only the
orphaned `layers` tree. This is not a regression -- the `layer_cache` table this revert
drops had no production caller that evicted anything either -- but the revert is the point
at which even the accounting for it went away.

## HTTP Streaming

```mermaid
sequenceDiagram
    participant CLI as Docker CLI
    participant Handler as ImageHandlers
    participant Writer as HTTPStreamWriter
    participant Manager as ImageManager
    participant Apple as Apple Framework

    CLI->>Handler: POST /images/create?fromImage=nginx
    Handler->>Manager: pullImage("nginx")
    Handler-->>Writer: Return streaming response

    Note over Handler,Writer: HTTP/1.1 200 OK<br/>Transfer-Encoding: chunked<br/>Content-Type: application/json

    loop For each progress event
        Apple->>Manager: Progress event
        Manager->>Writer: JSON + newline
        Writer->>CLI: {"status":"Downloading",...}\n
    end

    Manager-->>Writer: Pull complete
    Writer->>CLI: {"status":"Pull complete"}\n
    Writer-->>CLI: Close stream
```

## Code Signing & Entitlements

```mermaid
graph LR
    Source[Swift Source Code]
    Build[swift build]
    Binary[Arca Binary]
    Sign[codesign]
    Entitled[Signed Binary<br/>with Entitlements]
    Run[Execute]

    Source --> Build
    Build --> Binary
    Binary --> Sign
    Sign --> Entitled
    Entitled --> Run

    Entitlements[Arca.entitlements<br/>- Virtualization<br/>- Network Client<br/>- Network Server]

    Entitlements -.->|Applied during| Sign

    Run -->|Access| Apple[Apple Containerization<br/>Framework]

    style Entitlements fill:#ffe1e1
    style Apple fill:#ffe1e1
    style Entitled fill:#e1ffe1
```

## Performance Characteristics

| Component | Metric | Value | Notes |
|-----------|--------|-------|-------|
| **Container Startup** | Time | 1-3 seconds | VM initialization overhead |
| **Memory per Container** | RAM | 50-100 MB | VM overhead vs namespace isolation |
| **Network Latency** | WireGuard | ~1 ms | Peer-to-peer tunnels |
| **Network Latency** | vmnet | ~0.5 ms | Native Apple networking |
| **Image Pull** | Parallelism | 8 concurrent | Apple's parallel downloader |
| **Image Storage** | Type | Content-addressable | Layer deduplication |

## Key Design Decisions

### 1. WireGuard for Default Networking
**Why?** Full Docker API compatibility, dynamic network operations, multi-network support
**Trade-off:** Slightly higher latency (~1ms vs ~0.5ms for vmnet) but much more flexible

### 2. Container Persistence via SQLite
**Why?** Containers survive daemon restarts, Docker-compatible behavior
**Trade-off:** Added complexity, database maintenance

### 3. VirtioFS for Default Volumes
**Why?** Simple, reliable, shareable across containers
**Trade-off:** Some filesystem features limited vs native Linux

### 4. Buildx Integration (Not Custom Build API)
**Why?** Full feature coverage, zero maintenance, future-proof
**Trade-off:** Requires buildx installed, can't customize build internals

### 5. VM per Container (Apple's Model)
**Why?** Strong isolation, required by Apple's framework
**Trade-off:** Higher resource usage vs namespace-based containers

### 6. One Composed Rootfs per Image (Upstream's Model)
**Why?** A block device per layer exhausts the engine's 26-letter device alphabet at
roughly 24 layers, and it is fork-local divergence from upstream Containerization
**Trade-off:** The first create for an image stacks every layer serially where the
fork unpacked them in parallel (`EXT4Unpacker.unpack` at `a5803b6` is a serial
`for (index, resolved) in resolvedLayers.enumerated()`; the fork's
`OverlayFSUnpacker` used a `withThrowingTaskGroup` with a stated concurrency limit of 3,
read at `6ede1d5`). The fork's unpack measured
`duration_seconds=14.83 layers=36` on 2026-08-21, on host `newcombe`, with the engine
built from arca `c545612`, against the gascan workspace image — the same run that produced
`no free indices are available for allocation`. The **36** is the engine's own log field,
quoted as emitted; the image is described elsewhere in this repository as 35 layers, and
nothing in this tree explains the difference of one. Do not reconcile the two by arithmetic
— re-derive both from a run. The composed equivalent has not been measured,
and the number belongs here once it is

## Development Architecture

```mermaid
graph LR
    subgraph "Development Tools"
        Make[Makefile<br/>Build orchestration]
        Scripts[scripts/<br/>Helper scripts]
        Tests[Tests/<br/>Integration tests]
    end

    subgraph "Build Process"
        SwiftBuild[swift build]
        CodeSign[codesign<br/>Apply entitlements]
        Binary[Arca Binary]
    end

    subgraph "Runtime"
        Daemon[Arca Daemon<br/>/tmp/arca.sock]
        DockerCLI[Docker CLI<br/>DOCKER_HOST=unix:///tmp/arca.sock]
    end

    Make --> SwiftBuild
    Make --> Scripts
    SwiftBuild --> CodeSign
    CodeSign --> Binary
    Binary --> Daemon

    DockerCLI --> Daemon
    Tests --> DockerCLI

    style Make fill:#e1f5ff
    style Binary fill:#e1ffe1
    style Daemon fill:#fff4e1
```

---

For more information, see:
- **DISTRIBUTION.md** - Build and release process
- **VMINIT_BUILD.md** - Building custom vminit
- **Source code** - `Sources/` directories with inline documentation
