@testable import ModelManager
import Foundation
import XCTest

final class ManagedModelRegistryTests: XCTestCase {
    func testAvailabilityUsesProviderValidationAndActualDiskUsage()
        async throws
    {
        let fixture = try makeFixture()
        let installation = fixture.paths.installationDirectory(
            for: fixture.descriptor
        )
        try FileManager.default.createDirectory(
            at: installation,
            withIntermediateDirectories: true
        )
        try Data("provider-model".utf8).write(
            to: installation.appendingPathComponent("model.bin")
        )
        let validator = ModelInstallationValidator { _, directory in
            guard FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("model.bin").path
            ) else {
                throw ValidationError.missingArtifact
            }
        }

        let availability = try await fixture.registry.availability(
            of: fixture.descriptor.id,
            validatedBy: validator
        )

        guard case let .installed(directory, usage) = availability else {
            return XCTFail("Expected a provider-validated installation.")
        }
        XCTAssertEqual(directory, installation)
        XCTAssertEqual(usage.logicalBytes, 14)
        XCTAssertEqual(usage.regularFileCount, 1)
    }

    func testInvalidProviderInstallationNamesItsReason() async throws {
        let fixture = try makeFixture()
        let installation = fixture.paths.installationDirectory(
            for: fixture.descriptor
        )
        try FileManager.default.createDirectory(
            at: installation,
            withIntermediateDirectories: true
        )
        let validator = ModelInstallationValidator { _, _ in
            throw ValidationError.missingArtifact
        }

        let availability = try await fixture.registry.availability(
            of: fixture.descriptor.id,
            validatedBy: validator
        )

        XCTAssertEqual(
            availability,
            .invalid(
                directory: installation,
                message: ValidationError.missingArtifact.localizedDescription
            )
        )
        XCTAssertFalse(availability.isInstalled)
    }

    func testUnknownIdentifierFailsBeforeTouchingStorage() async throws {
        let fixture = try makeFixture()
        let unknown = ModelIdentifier(rawValue: "test.unknown")

        do {
            _ = try await fixture.registry.diskUsage(of: unknown)
            XCTFail("Expected an unknown-model error.")
        } catch let error as ManagedModelRegistryError {
            XCTAssertEqual(error, .unknownModel(unknown))
        }
    }

    func testRemoveInstallationDeletesOnlyTheSelectedModelDirectory()
        async throws
    {
        let fixture = try makeFixture()
        let installation = fixture.paths.installationDirectory(
            for: fixture.descriptor
        )
        try FileManager.default.createDirectory(
            at: installation,
            withIntermediateDirectories: true
        )
        try Data("weights".utf8).write(
            to: installation.appendingPathComponent("model.bin")
        )
        let unrelated = fixture.paths.modelsDirectory
            .appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelated,
            withIntermediateDirectories: true
        )

        try await fixture.registry.removeInstallation(
            of: fixture.descriptor.id
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: installation.path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testRemovingAMissingInstallationIsIdempotent() async throws {
        let fixture = try makeFixture()

        try await fixture.registry.removeInstallation(
            of: fixture.descriptor.id
        )
        try await fixture.registry.removeInstallation(
            of: fixture.descriptor.id
        )
    }

    private func makeFixture() throws -> RegistryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: root.path) else {
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let descriptor = try ModelDescriptor(
            id: ModelIdentifier(rawValue: "test.registry"),
            displayName: "Registry test",
            detail: "",
            provider: .fluidAudio,
            task: .transcription,
            installationDirectoryName: "registry-test",
            supportedLanguages: ["en"],
            supportsLiveProcessing: true,
            windowGeometry: .init(duration: 14, overlap: 1.5)
        )
        let paths = ModelStoragePaths(modelsDirectory: root)
        return RegistryFixture(
            descriptor: descriptor,
            paths: paths,
            registry: ManagedModelRegistry(
                catalogue: try ModelCatalogue(models: [descriptor]),
                paths: paths
            )
        )
    }
}

private struct RegistryFixture {
    let descriptor: ModelDescriptor
    let paths: ModelStoragePaths
    let registry: ManagedModelRegistry
}

private enum ValidationError: Error, LocalizedError {
    case missingArtifact

    var errorDescription: String? {
        "The provider-required artifact is missing."
    }
}
