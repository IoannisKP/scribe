@testable import ModelManager
import Foundation
import XCTest

final class ModelDownloadControllerTests: XCTestCase {
    private static let helloDigest =
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    func testDownloadVerifiesAndAtomicallyInstalls() async throws {
        let fixture = try makeFixture()
        let transport = ImmediateTransport(data: Data("hello".utf8))

        let installed = try await fixture.controller.start(
            fixture.plan,
            using: transport
        )

        XCTAssertEqual(
            installed,
            fixture.paths.installationDirectory(for: fixture.plan.model)
        )
        XCTAssertEqual(
            try Data(contentsOf: installed.appendingPathComponent("model.bin")),
            Data("hello".utf8)
        )
        let installedState = await fixture.controller.state(
            for: fixture.plan.model.id
        )
        XCTAssertEqual(installedState, .installed(installed))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.stagingDirectory(
                    for: fixture.plan.model
                ).path
            )
        )
    }

    func testPausePreservesResumeDataAndResumeInstalls() async throws {
        let fixture = try makeFixture()
        let pausingTransport = SuspendingTransport()
        let task = Task {
            try await fixture.controller.start(
                fixture.plan,
                using: pausingTransport
            )
        }
        await pausingTransport.waitUntilStarted()

        try await fixture.controller.pause(fixture.plan.model.id)
        do {
            _ = try await task.value
            XCTFail("The original transfer should stop after pause.")
        } catch is CancellationError {
            // Expected: resume is a separate transfer invocation.
        }
        guard case .paused = await fixture.controller.state(
            for: fixture.plan.model.id
        ) else {
            return XCTFail("Expected a paused download state.")
        }

        let resumedTransport = ImmediateTransport(data: Data("hello".utf8))
        _ = try await fixture.controller.resume(
            fixture.plan,
            using: resumedTransport
        )
        let receivedResumeData = await resumedTransport.receivedResumeData
        XCTAssertEqual(receivedResumeData, Data("resume-token".utf8))
    }

    func testCancelStopsTransportAndRemovesStaging() async throws {
        let fixture = try makeFixture()
        let transport = SuspendingTransport()
        let task = Task {
            try await fixture.controller.start(
                fixture.plan,
                using: transport
            )
        }
        await transport.waitUntilStarted()

        await fixture.controller.cancel(fixture.plan.model)
        do {
            _ = try await task.value
            XCTFail("Cancelled transfer unexpectedly completed.")
        } catch is CancellationError {
            // Expected.
        }
        let cancelledState = await fixture.controller.state(
            for: fixture.plan.model.id
        )
        let wasCancelled = await transport.wasCancelled
        XCTAssertEqual(cancelledState, .cancelled)
        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.stagingDirectory(
                    for: fixture.plan.model
                ).path
            )
        )
    }

    func testChecksumMismatchNeverPromotesInstallation() async throws {
        let fixture = try makeFixture()
        let transport = ImmediateTransport(data: Data("wrong".utf8))

        do {
            _ = try await fixture.controller.start(
                fixture.plan,
                using: transport
            )
            XCTFail("Expected checksum verification to fail.")
        } catch let error as ModelIntegrityError {
            guard case .checksumMismatch = error else {
                return XCTFail("Unexpected integrity error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.installationDirectory(
                    for: fixture.plan.model
                ).path
            )
        )
        guard case .failed = await fixture.controller.state(
            for: fixture.plan.model.id
        ) else {
            return XCTFail("Expected a failed download state.")
        }
    }

    func testManifestRejectsTraversalAndDuplicateArtifacts() throws {
        XCTAssertThrowsError(
            try ModelArtifactIntegrity(
                relativePath: "../model.bin",
                expectedByteCount: 5,
                sha256: Self.helloDigest
            )
        )
        let artifact = try ModelArtifactIntegrity(
            relativePath: "model.bin",
            expectedByteCount: 5,
            sha256: Self.helloDigest
        )
        XCTAssertThrowsError(
            try ModelIntegrityManifest(artifacts: [artifact, artifact])
        ) { error in
            XCTAssertEqual(
                error as? ModelIntegrityError,
                .duplicateArtifact("model.bin")
            )
        }
    }

    func testVerifierRejectsSymlinkOutsideInstallation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installation = root.appendingPathComponent(
            "installation",
            isDirectory: true
        )
        let outside = root.appendingPathComponent("outside.bin")
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: installation,
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: installation.appendingPathComponent("model.bin"),
            withDestinationURL: outside
        )
        let artifact = try ModelArtifactIntegrity(
            relativePath: "model.bin",
            expectedByteCount: 5,
            sha256: Self.helloDigest
        )
        let manifest = try ModelIntegrityManifest(artifacts: [artifact])

        do {
            try await ModelIntegrityVerifier().verify(
                directory: installation,
                manifest: manifest
            )
            XCTFail("Expected an escaping symlink to be rejected.")
        } catch let error as ModelIntegrityError {
            XCTAssertEqual(
                error,
                .artifactEscapesInstallation("model.bin")
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        let paths = ModelStoragePaths(modelsDirectory: root)
        let model = try ModelDescriptor(
            id: ModelIdentifier(rawValue: "test.download"),
            displayName: "Download test",
            detail: "",
            provider: .whisperKit,
            task: .transcription,
            installationDirectoryName: "test-download",
            supportedLanguages: ["en"],
            supportsLiveProcessing: false,
            windowGeometry: .init(duration: 30, overlap: 0)
        )
        let artifact = try ModelArtifactIntegrity(
            relativePath: "model.bin",
            expectedByteCount: 5,
            sha256: Self.helloDigest
        )
        return Fixture(
            paths: paths,
            plan: ModelDownloadPlan(
                model: model,
                integrityManifest: try ModelIntegrityManifest(
                    artifacts: [artifact]
                )
            ),
            controller: ModelDownloadController(paths: paths)
        )
    }
}

private struct Fixture {
    let paths: ModelStoragePaths
    let plan: ModelDownloadPlan
    let controller: ModelDownloadController
}

private actor ImmediateTransport: ModelDownloadTransport {
    private let data: Data
    private(set) var receivedResumeData: Data?

    init(data: Data) {
        self.data = data
    }

    func transfer(
        to stagingDirectory: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        receivedResumeData = resumeData
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: stagingDirectory.appendingPathComponent("model.bin")
        )
        await progress(
            ModelDownloadProgress(
                fractionCompleted: 1,
                downloadedBytes: Int64(data.count),
                totalBytes: Int64(data.count)
            )
        )
    }

    func pause() -> Data? {
        nil
    }

    func cancel() {}
}

private actor SuspendingTransport: ModelDownloadTransport {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private(set) var wasCancelled = false

    func transfer(
        to _: URL,
        resumeData _: Data?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await progress(
            ModelDownloadProgress(
                fractionCompleted: 0.4,
                downloadedBytes: 2,
                totalBytes: 5
            )
        )
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func pause() -> Data? {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        return Data("resume-token".utf8)
    }

    func cancel() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
