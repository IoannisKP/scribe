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

    func testRemoveInstallationMovesOnlySelectedModelToTrashIntact()
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

        let trashed = try await fixture.registry.removeInstallation(
            of: fixture.descriptor.id
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: installation.path)
        )
        let trashedDirectory = try XCTUnwrap(trashed)
        XCTAssertEqual(
            try Data(
                contentsOf: trashedDirectory
                    .appendingPathComponent("model.bin")
            ),
            Data("weights".utf8)
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

    func testUnrecognizedFolderScanMeasuresAndMovesOnlyOrphanToTrash()
        async throws
    {
        let fixture = try makeFixture()
        let known = fixture.paths.installationDirectory(
            for: fixture.descriptor
        )
        let orphan = fixture.paths.modelsDirectory.appendingPathComponent(
            "orphan-model",
            isDirectory: true
        )
        let nested = orphan.appendingPathComponent(
            "Nested",
            isDirectory: true
        )
        let staging = fixture.paths.modelsDirectory.appendingPathComponent(
            ".Downloads",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: known,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(
            to: orphan.appendingPathComponent("one.bin")
        )
        try Data([4, 5, 6, 7]).write(
            to: nested.appendingPathComponent("two.bin")
        )

        let unrecognized = try await fixture.registry
            .unrecognizedDirectories()

        XCTAssertEqual(unrecognized.map(\.name), ["orphan-model"])
        XCTAssertEqual(unrecognized.first?.diskUsage.logicalBytes, 7)
        XCTAssertEqual(unrecognized.first?.diskUsage.regularFileCount, 2)

        let trashed = try await fixture.registry.removeUnrecognizedDirectory(
            named: "orphan-model"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(trashed.deletingLastPathComponent(), fixture.trashDirectory)
        let trashedUsage = try await ModelDiskAccounting().usage(
            ofDirectory: trashed
        )
        XCTAssertEqual(trashedUsage.logicalBytes, 7)
        XCTAssertEqual(trashedUsage.regularFileCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: known.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testOptionalConfirmedOrphanMovesToSystemTrashIntact()
        async throws
    {
        guard
            let confirmedPath = ProcessInfo.processInfo.environment[
                "SCRIBE_CONFIRMED_ORPHAN_TRASH_PATH"
            ]
        else {
            throw XCTSkip(
                "Set SCRIBE_CONFIRMED_ORPHAN_TRASH_PATH to exercise one explicitly confirmed orphan against macOS Trash."
            )
        }
        let source = URL(fileURLWithPath: confirmedPath)
            .standardizedFileURL
        XCTAssertEqual(source.lastPathComponent, "openai_whisper-small_216MB")
        XCTAssertEqual(
            source.deletingLastPathComponent().lastPathComponent,
            "Models"
        )
        let descriptor = try ModelDescriptor(
            id: ModelIdentifier(rawValue: "test.system-trash"),
            displayName: "System Trash test",
            detail: "",
            provider: .fluidAudio,
            task: .transcription,
            installationDirectoryName: "system-trash-managed-sentinel",
            supportedLanguages: ["en"],
            windowGeometry: .init(duration: 14, overlap: 1.5)
        )
        let paths = ModelStoragePaths(
            modelsDirectory: source.deletingLastPathComponent()
        )
        let registry = ManagedModelRegistry(
            catalogue: try ModelCatalogue(models: [descriptor]),
            paths: paths
        )
        let accounting = ModelDiskAccounting()
        let before = try await accounting.usage(ofDirectory: source)
        XCTAssertTrue(before.isInstalled)

        let trashed = try await registry.removeUnrecognizedDirectory(
            named: source.lastPathComponent
        )

        let after = try await accounting.usage(ofDirectory: trashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(after.isInstalled)
        XCTAssertEqual(after.logicalBytes, before.logicalBytes)
        XCTAssertEqual(after.regularFileCount, before.regularFileCount)
        print("Confirmed orphan moved intact to \(trashed.path)")
    }

    func testUnrecognizedRemovalRejectsManagedAndUnsafeNames()
        async throws
    {
        let fixture = try makeFixture()

        do {
            try await fixture.registry.removeUnrecognizedDirectory(
                named: fixture.descriptor.installationDirectoryName
            )
            XCTFail("Expected a managed-directory rejection.")
        } catch let error as ManagedModelRegistryError {
            XCTAssertEqual(
                error,
                .managedDirectoryCannotBeRemoved(
                    fixture.descriptor.installationDirectoryName
                )
            )
        }

        do {
            try await fixture.registry.removeUnrecognizedDirectory(
                named: "../outside"
            )
            XCTFail("Expected an unsafe-name rejection.")
        } catch let error as ManagedModelRegistryError {
            XCTAssertEqual(
                error,
                .invalidUnrecognizedDirectoryName("../outside")
            )
        }
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
            windowGeometry: .init(duration: 14, overlap: 1.5)
        )
        let paths = ModelStoragePaths(modelsDirectory: root)
        let trashDirectory = root.appendingPathComponent(
            ".TestTrash",
            isDirectory: true
        )
        let folderTrash = ModelFolderTrash { directory in
            try FileManager.default.createDirectory(
                at: trashDirectory,
                withIntermediateDirectories: true
            )
            let destination = trashDirectory.appendingPathComponent(
                directory.lastPathComponent,
                isDirectory: true
            )
            try FileManager.default.moveItem(at: directory, to: destination)
            return destination
        }
        return RegistryFixture(
            descriptor: descriptor,
            paths: paths,
            trashDirectory: trashDirectory,
            registry: ManagedModelRegistry(
                catalogue: try ModelCatalogue(models: [descriptor]),
                paths: paths,
                folderTrash: folderTrash
            )
        )
    }
}

private struct RegistryFixture {
    let descriptor: ModelDescriptor
    let paths: ModelStoragePaths
    let trashDirectory: URL
    let registry: ManagedModelRegistry
}

private enum ValidationError: Error, LocalizedError {
    case missingArtifact

    var errorDescription: String? {
        "The provider-required artifact is missing."
    }
}
