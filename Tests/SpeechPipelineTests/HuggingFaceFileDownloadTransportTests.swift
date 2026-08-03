import CryptoKit
import Foundation
import ModelManager
@testable import SpeechPipeline
import XCTest

final class HuggingFaceFileDownloadTransportTests: XCTestCase {
    func testDownloadsProjectedFilesReportsBytesAndSkipsCompleteFilesOnResume()
        async throws
    {
        let staging = try makeTestDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: staging) }
        let first = Data("first".utf8)
        let second = Data("second artifact".utf8)
        let artifacts = [
            try artifact(path: "Model.mlmodelc/weights.bin", data: first),
            try artifact(path: "tokenizer.json", data: second),
        ]
        let fixture = DownloadFixture(files: [
            "/first": first,
            "/second": second,
        ])
        let recorder = ProgressRecorder()
        let transport = HuggingFaceFileDownloadTransport(
            artifacts: artifacts
        ) { url in
            try await fixture.download(url)
        }

        try await transport.transfer(
            to: staging,
            resumeData: nil
        ) { snapshot in
            await recorder.append(snapshot)
        }

        let manifest = try ModelIntegrityManifest(
            artifacts: artifacts.map(\.integrity)
        )
        try await ModelIntegrityVerifier().verify(
            directory: staging,
            manifest: manifest
        )
        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots.last?.fractionCompleted, 1)
        XCTAssertEqual(
            snapshots.last?.downloadedBytes,
            Int64(first.count + second.count)
        )
        let initialRequestCount = await fixture.requestCount
        XCTAssertEqual(initialRequestCount, 2)

        let resumeFixture = DownloadFixture(files: [:])
        let resumed = HuggingFaceFileDownloadTransport(
            artifacts: artifacts
        ) { url in
            try await resumeFixture.download(url)
        }
        try await resumed.transfer(
            to: staging,
            resumeData: Data("resume".utf8)
        ) { _ in }
        let resumeRequestCount = await resumeFixture.requestCount
        XCTAssertEqual(resumeRequestCount, 0)
    }

    private func artifact(
        path: String,
        data: Data
    ) throws -> HuggingFaceResolvedArtifact {
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        let remoteName = path.hasPrefix("Model") ? "first" : "second"
        return try HuggingFaceResolvedArtifact(
            integrity: ModelArtifactIntegrity(
                relativePath: path,
                expectedByteCount: Int64(data.count),
                sha256: digest
            ),
            downloadURL: XCTUnwrap(
                URL(string: "https://example.invalid/\(remoteName)")
            )
        )
    }
}

private actor DownloadFixture {
    private let files: [String: Data]
    private(set) var requestCount = 0

    init(files: [String: Data]) {
        self.files = files
    }

    func download(_ url: URL) throws -> URL {
        requestCount += 1
        guard let data = files[url.path] else {
            throw URLError(.fileDoesNotExist)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary)
        return temporary
    }
}

private actor ProgressRecorder {
    private(set) var snapshots: [ModelDownloadProgress] = []

    func append(_ snapshot: ModelDownloadProgress) {
        snapshots.append(snapshot)
    }
}
