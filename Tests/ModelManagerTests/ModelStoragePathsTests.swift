@testable import ModelManager
import Foundation
import XCTest

final class ModelStoragePathsTests: XCTestCase {
    func testApplicationSupportLayoutIsCentralized() throws {
        let applicationSupport = URL(
            fileURLWithPath: "/tmp/Application Support",
            isDirectory: true
        )
        let paths = ModelStoragePaths(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(
            paths.scribeDirectory.path,
            "/tmp/Application Support/Scribe"
        )
        XCTAssertEqual(
            paths.modelsDirectory.path,
            "/tmp/Application Support/Scribe/Models"
        )
        let catalogue = try ScribeModelCatalogue.builtIn()
        let parakeet = try XCTUnwrap(
            catalogue[ScribeModelIdentifiers.parakeetV3Multilingual]
        )
        XCTAssertEqual(
            paths.installationDirectory(for: parakeet).path,
            "/tmp/Application Support/Scribe/Models/parakeet-tdt-0.6b-v3"
        )
        XCTAssertEqual(
            paths.stagingDirectory(for: parakeet).path,
            "/tmp/Application Support/Scribe/Models/.Downloads/parakeet-tdt-0.6b-v3"
        )
    }

    func testInjectedModelsDirectoryRemainsExact() {
        let injected = URL(
            fileURLWithPath: "/tmp/isolated-model-test",
            isDirectory: true
        )
        let paths = ModelStoragePaths(modelsDirectory: injected)

        XCTAssertEqual(paths.modelsDirectory, injected.standardizedFileURL)
    }

    func testEveryBuiltInInstallationStaysInsideModelsDirectory()
        throws
    {
        let paths = ModelStoragePaths(
            modelsDirectory: URL(
                fileURLWithPath: "/tmp/Models",
                isDirectory: true
            )
        )
        for model in try ScribeModelCatalogue.builtIn().models {
            let installation = paths.installationDirectory(for: model)
            XCTAssertEqual(
                installation.deletingLastPathComponent(),
                paths.modelsDirectory
            )
        }
    }
}
