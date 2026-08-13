import ContainerBridge
import Foundation
import Logging
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

/// `PrepareImage`: hold-or-fail, and never a fetch.
///
/// Every test here seeds through the real path -- `loadWorkspaceImages`, the
/// function `arca-engine image load` calls, over a real `OCILayoutFixture`
/// layout -- rather than through a stub image manager. The question the method
/// answers is entirely about what a real `ImageStore` holds, and a stub would
/// answer it by construction.
///
/// **The shape these are built against.** `Ack` carries no payload
/// (`engine.proto:74`), so a test that asserts "it returned `Ack`" passes
/// against a method whose whole body is `PrepareImageResponse.with { $0.ok =
/// Ack() }`. Asserting a success alone therefore proves nothing at all. Every
/// success assertion below is paired, in the same test, with a request that
/// must be refused -- so that a body which cannot tell the two apart fails.
final class PrepareImageTests: XCTestCase {
    private let logger = Logger(label: "prepare-image-tests")

    /// A workspace image, not `arca-vminit:latest`: this method exists for
    /// content a consumer pushes, and a test that prepared vminit through it
    /// would prove the two are interchangeable.
    private static let reference = "workspace:latest"
    private static let repository = "workspace"

    // MARK: - Content the engine holds

    /// The success arm, and the discriminating refusal that makes it mean
    /// something.
    ///
    /// The second half is not a bonus assertion -- it is what stops the first
    /// half passing against a method that looks nothing up. The two requests
    /// differ in one hex character, both name a repository the store really
    /// holds, and a body that answers `Ack` unconditionally fails on the second.
    func testHeldContentIsPreparedAndTheSameRepositoryUnderAnotherDigestIsNot() async throws {
        let engine = try await preparedEngine()

        let held = await engine.service.prepareImage(request: request(
            repository: Self.repository, hex: engine.hex
        ))
        guard case .ok = held.outcome else {
            return XCTFail("content the engine holds must be prepared, got \(held.outcome as Any)")
        }

        let flipped = flipFirstCharacter(of: engine.hex)
        let absent = await engine.service.prepareImage(request: request(
            repository: Self.repository, hex: flipped
        ))
        guard case .error(let error) = absent.outcome else {
            return XCTFail("a digest the store does not hold must be refused, got \(absent.outcome as Any)")
        }
        XCTAssertEqual(error.code, "not_found")
        XCTAssertEqual(error.resource, "\(Self.repository)@sha256:\(flipped)")
        XCTAssertEqual(
            error.message,
            "this engine holds no image with that content digest and will not fetch one; "
                + "load it with 'arca-engine image load --oci-layout <dir>'"
        )
    }

    // MARK: - Content the engine does not hold

    /// Absent content is `not_found`, final, and never a fetch.
    ///
    /// The request is deliberately shaped like one a registry could serve --
    /// `docker.io/library/alpine` and a well-formed digest -- because that is
    /// the frame a caller would send if it expected the engine to go and get
    /// the content. A `PrepareImage` that fell back to `ImageManager.pullImage`
    /// fails here: the code would be a pull failure rather than `not_found`,
    /// or, on a host that could reach the registry, `ok`. This is the structural
    /// guard against that fallback -- worth more than a comment saying there
    /// is none.
    ///
    /// Asserted field by field on exact equality. `resource` and `message` are
    /// not interchangeable (`EngineErrors.swift:32-35`), and a transposition
    /// survives any assertion weaker than this.
    func testContentTheEngineNeverHeldIsNotFoundAndIsNeverFetched() async throws {
        let service = SandboxEngineService.forTesting(
            stateRoot: try temporaryEngineRoot().appendingPathComponent("state"),
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux")
        )
        let hex = String(repeating: "ab", count: 32)

        let response = await service.prepareImage(request: request(
            repository: "docker.io/library/alpine", hex: hex
        ))

        guard case .error(let error) = response.outcome else {
            return XCTFail("absent content must be refused, got \(response.outcome as Any)")
        }
        XCTAssertEqual(error.code, "not_found")
        XCTAssertEqual(error.resource, "docker.io/library/alpine@sha256:\(hex)")
        XCTAssertEqual(
            error.message,
            "this engine holds no image with that content digest and will not fetch one; "
                + "load it with 'arca-engine image load --oci-layout <dir>'"
        )
    }

    /// The forgiving-match test on the repository axis.
    ///
    /// The digest is one the store really holds; only the repository differs.
    /// Answering `Ack` here would be a success the consumer cannot check,
    /// followed by a `Create` that fails, because `ContainerManager` resolves
    /// the image by the reference it is given.
    func testContentHeldUnderAnotherRepositoryIsNotFound() async throws {
        let engine = try await preparedEngine()

        let response = await engine.service.prepareImage(request: request(
            repository: "not-the-workspace", hex: engine.hex
        ))

        guard case .error(let error) = response.outcome else {
            return XCTFail("a foreign repository must be refused, got \(response.outcome as Any)")
        }
        XCTAssertEqual(error.code, "not_found")
        XCTAssertEqual(error.resource, "not-the-workspace@sha256:\(engine.hex)")
        XCTAssertEqual(
            error.message,
            "this engine holds that content digest under repository workspace, "
                + "not not-the-workspace"
        )
    }

    /// An image row can outlive the blobs it names, and this is the case that
    /// separates a real check from a cheap one.
    ///
    /// Deleting the layer blob under the store's own root is the damage a
    /// half-finished load or an interrupted content GC leaves behind. The
    /// `imageExists` assertion in the middle is the premise, not decoration: it
    /// is the cheap answer this method deliberately does not use, and it says
    /// "held" for an image nothing can be created from, because it is built on
    /// `inspectImage`, which reads the index, the manifest and the config and
    /// never a layer.
    func testAnImageMissingALayerBlobIsNotFound() async throws {
        let engine = try await preparedEngine()
        let layer = try XCTUnwrap(
            engine.layers.first,
            "the fixture image must name a layer for this test to delete one"
        )
        try FileManager.default.removeItem(
            at: engine.storeRoot
                .appendingPathComponent("content/blobs/sha256")
                .appendingPathComponent(layer.replacingOccurrences(of: "sha256:", with: ""))
        )
        let cheapAnswer = await engine.service.imageManager.imageExists(nameOrId: Self.reference)
        XCTAssertTrue(
            cheapAnswer,
            "the premise of this test is that the cheap check cannot see the missing layer"
        )

        let response = await engine.service.prepareImage(request: request(
            repository: Self.repository, hex: engine.hex
        ))

        guard case .error(let error) = response.outcome else {
            return XCTFail("an image whose layer is gone must be refused, got \(response.outcome as Any)")
        }
        XCTAssertEqual(error.code, "not_found")
        XCTAssertEqual(error.resource, "\(Self.repository)@sha256:\(engine.hex)")
        XCTAssertEqual(
            error.message,
            "the image stored as \(Self.reference) carries that content digest, but this engine "
                + "does not hold 1 of the blobs it names: \(layer)"
        )
    }

    // MARK: - Requests that are not digests

    /// A malformed digest is the consumer's error, not a statement about
    /// content.
    ///
    /// `not_found` would tell a consumer to go and load the content, which
    /// cannot be the fix for a request that never named any.
    /// `invalid_resource_identity` is the code for an identity the engine
    /// cannot read, and it is one of the twelve gascan's table accepts.
    ///
    /// The unset request is in the table on purpose: `image` is a message
    /// field, so a request that omits it arrives with both halves empty and
    /// must not be read as a lookup for the empty digest.
    func testARequestThatIsNotADigestIsAnInvalidIdentity() async throws {
        let service = SandboxEngineService.forTesting()
        let cases: [(name: String, request: Arca_Engine_V1_PrepareImageRequest, resource: String)] = [
            ("unset", Arca_Engine_V1_PrepareImageRequest(), "@sha256:"),
            (
                "no repository",
                request(repository: "", hex: String(repeating: "a", count: 64)),
                "@sha256:" + String(repeating: "a", count: 64)
            ),
            ("no hex", request(repository: "workspace", hex: ""), "workspace@sha256:"),
            (
                "short hex",
                request(repository: "workspace", hex: String(repeating: "a", count: 63)),
                "workspace@sha256:" + String(repeating: "a", count: 63)
            ),
            (
                "uppercase hex",
                request(repository: "workspace", hex: String(repeating: "A", count: 64)),
                "workspace@sha256:" + String(repeating: "A", count: 64)
            ),
            (
                "prefixed hex",
                request(repository: "workspace", hex: "sha256:" + String(repeating: "a", count: 57)),
                "workspace@sha256:sha256:" + String(repeating: "a", count: 57)
            ),
        ]

        for (name, request, resource) in cases {
            let response = await service.prepareImage(request: request)
            guard case .error(let error) = response.outcome else {
                XCTFail("\(name) must be refused, got \(response.outcome as Any)")
                continue
            }
            XCTAssertEqual(error.code, "invalid_resource_identity", "\(name) answered \(error.code)")
            XCTAssertEqual(error.resource, resource, "\(name) named \(error.resource)")
            XCTAssertEqual(
                error.message,
                "an image digest is a non-empty repository and a 64-character lowercase hex "
                    + "sha256 carrying no prefix",
                "\(name) said \(error.message)"
            )
        }
    }

    // MARK: - The error arm is never a thrown Swift error

    /// A store that cannot be read is an error *outcome*, never a throw.
    ///
    /// An uncaught throw in a provider method becomes a gRPC status, and
    /// `engine.proto:52-58` reserves status codes for transport faults -- an
    /// unreachable engine, a broken stream. A status where an outcome belongs
    /// tells the consumer the engine is gone when the truth is that one read
    /// failed.
    ///
    /// The fault is injected into the store's own `state.json`, which is what
    /// `ImageStore.list()` reads to know which images exist, so the throw comes
    /// out of ContainerBridge exactly as a real one would. `command_io` is the
    /// code the other two implemented methods already use for a read that
    /// failed.
    ///
    /// `message` is asserted non-empty rather than by equality: it is the
    /// underlying decode error interpolated, and pinning a Foundation error's
    /// description would assert on a string this project does not own.
    func testAnUnreadableStoreIsAnErrorOutcomeAndNotAThrownError() async throws {
        let engine = try await preparedEngine()
        try Data("not json".utf8).write(
            to: engine.storeRoot.appendingPathComponent("state.json")
        )

        let response = await engine.service.prepareImage(request: request(
            repository: Self.repository, hex: engine.hex
        ))

        guard case .error(let error) = response.outcome else {
            return XCTFail("an unreadable store must answer an error, got \(response.outcome as Any)")
        }
        XCTAssertEqual(error.code, "command_io")
        XCTAssertEqual(error.resource, "\(Self.repository)@sha256:\(engine.hex)")
        XCTAssertFalse(error.message.isEmpty, "the failure must carry the cause")
    }

    // MARK: - The split both sides have to agree on

    /// The repository of a stored reference, split the way the consumer splits
    /// its own (`crates/gascan-core/src/runtime.rs:704-715`).
    ///
    /// The registry-port row is the one that matters: a rule that took the last
    /// `:` unconditionally would turn `registry.example:5000/repo` into
    /// `registry.example`, and every image from a private registry would be
    /// refused as held under some other repository.
    func testAStoredReferenceIsSplitTheWayTheConsumerSplitsItsOwn() {
        XCTAssertEqual(imageRepository(ofReference: "workspace:latest"), "workspace")
        XCTAssertEqual(imageRepository(ofReference: "workspace"), "workspace")
        XCTAssertEqual(
            imageRepository(ofReference: "docker.io/library/alpine:3.19"),
            "docker.io/library/alpine"
        )
        XCTAssertEqual(
            imageRepository(ofReference: "registry.example:5000/repo"),
            "registry.example:5000/repo"
        )
        XCTAssertEqual(
            imageRepository(ofReference: "registry.example:5000/repo:v1"),
            "registry.example:5000/repo"
        )
        XCTAssertEqual(
            imageRepository(ofReference: "workspace:latest@sha256:" + String(repeating: "a", count: 64)),
            "workspace"
        )
    }

    // MARK: - Seeding

    /// A service, and a store that really holds the fixture image.
    private struct PreparedEngine {
        let service: SandboxEngineService
        let storeRoot: URL
        /// The bare hex of the digest the store recorded, read back from the
        /// store rather than computed here. Containerization synthesizes an
        /// index for a single-manifest layout during the import, so the digest
        /// the store holds is not one this test could state in advance without
        /// re-implementing that synthesis and trusting the two to stay equal.
        let hex: String
        /// The layer digests the stored image names, in `sha256:<hex>` form.
        let layers: [String]
    }

    private func preparedEngine(
        reference: String = PrepareImageTests.reference
    ) async throws -> PreparedEngine {
        let root = try temporaryEngineRoot()
        let stateRoot = root.appendingPathComponent("state")
        let report = try await loadWorkspaceImages(
            fromOCILayout: try OCILayoutFixture.write(
                at: root.appendingPathComponent("workspace"),
                reference: reference,
                payload: "pushed by the consumer, not by startup"
            ),
            stateRoot: stateRoot,
            logger: logger
        )
        XCTAssertEqual(
            report.references, [reference],
            "the seed must put the reference these tests ask about into the store"
        )

        let service = SandboxEngineService.forTesting(
            stateRoot: stateRoot, kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux")
        )
        let stored = try await service.imageManager.inspectImage(nameOrId: reference)
        let details = try XCTUnwrap(
            stored, "the store must report details for the image it just loaded"
        )
        let digest = try XCTUnwrap(
            details.repoDigests.first,
            "the store must report a digest for the image it just loaded"
        )
        return PreparedEngine(
            service: service,
            storeRoot: report.storeRoot,
            hex: digest.replacingOccurrences(of: "sha256:", with: ""),
            layers: details.rootFS.layers
        )
    }

    private func request(repository: String, hex: String) -> Arca_Engine_V1_PrepareImageRequest {
        Arca_Engine_V1_PrepareImageRequest.with {
            $0.image = Arca_Engine_V1_ImageDigest.with {
                $0.repository = repository
                $0.sha256Hex = hex
            }
        }
    }

    /// A well-formed digest that is certainly not the one given.
    ///
    /// One character, so the two differ in nothing else: a test that changed
    /// the length or the alphabet as well would be refused for being malformed
    /// and would never reach the lookup it exists to drive.
    private func flipFirstCharacter(of hex: String) -> String {
        let first = hex.first == "0" ? "1" : "0"
        return first + hex.dropFirst()
    }
}
