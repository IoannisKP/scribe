@testable import SpeechPipeline
import Foundation
import ModelManager
import XCTest

final class HuggingFaceIntegrityManifestResolverTests: XCTestCase {
    func testBuildsManifestFromLFSHashesAndHashesSmallGitFiles()
        async throws
    {
        let fixture = ManifestFetchFixture()
        let resolver = HuggingFaceIntegrityManifestResolver { url in
            try await fixture.data(for: url)
        }
        let source = try HuggingFaceModelSource(
            repository: "Provider/model",
            requiredRoots: ["Bundle.mlmodelc", "token.json"]
        )

        let manifest = try await resolver.resolve(source)

        XCTAssertEqual(
            manifest.artifacts,
            [
                try ModelArtifactIntegrity(
                    relativePath: "Bundle.mlmodelc/weights.bin",
                    expectedByteCount: 3,
                    sha256: String(repeating: "a", count: 64)
                ),
                try ModelArtifactIntegrity(
                    relativePath: "token.json",
                    expectedByteCount: 5,
                    sha256:
                        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                ),
            ]
        )
        let requestedPaths = await fixture.requestedPaths
        XCTAssertEqual(
            requestedPaths,
            [
                "/api/models/Provider/model/tree/main",
                "/api/models/Provider/model/tree/main/Bundle.mlmodelc",
                "/Provider/model/resolve/main/token.json",
            ]
        )
    }

    func testMissingRequiredRootFailsClosed() async throws {
        let fixture = ManifestFetchFixture()
        let resolver = HuggingFaceIntegrityManifestResolver { url in
            try await fixture.data(for: url)
        }
        let source = try HuggingFaceModelSource(
            repository: "Provider/model",
            requiredRoots: ["missing.bin"]
        )

        do {
            _ = try await resolver.resolve(source)
            XCTFail("Expected a missing-root error.")
        } catch let error as HuggingFaceManifestError {
            XCTAssertEqual(error, .missingRoot("missing.bin"))
        }
    }
}

private actor ManifestFetchFixture {
    private(set) var requestedPaths: [String] = []

    func data(for url: URL) throws -> Data {
        requestedPaths.append(url.path)
        switch url.path {
        case "/api/models/Provider/model/tree/main":
            return Data(
                """
                [
                  {"type":"directory","path":"Bundle.mlmodelc","size":0,"lfs":null},
                  {"type":"file","path":"token.json","size":5,"lfs":null}
                ]
                """.utf8
            )
        case "/api/models/Provider/model/tree/main/Bundle.mlmodelc":
            return Data(
                """
                [
                  {
                    "type":"file",
                    "path":"Bundle.mlmodelc/weights.bin",
                    "size":3,
                    "lfs":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":3}
                  }
                ]
                """.utf8
            )
        case "/Provider/model/resolve/main/token.json":
            return Data("hello".utf8)
        default:
            throw FixtureError.unexpectedURL(url)
        }
    }
}

private enum FixtureError: Error {
    case unexpectedURL(URL)
}
