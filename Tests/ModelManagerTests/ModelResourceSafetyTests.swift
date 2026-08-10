@testable import ModelManager
import Foundation
import XCTest

final class ModelResourceSafetyTests: XCTestCase {
    func testDiskAccountingMeasuresNestedRegularFiles() async throws {
        let fixture = try makeDescriptor(profile: nil)
        let installation = fixture.paths.installationDirectory(
            for: fixture.descriptor
        )
        let nested = installation.appendingPathComponent(
            "Nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(
            to: installation.appendingPathComponent("one.bin")
        )
        try Data([4, 5, 6, 7, 8]).write(
            to: nested.appendingPathComponent("two.bin")
        )

        let usage = try await ModelDiskAccounting().usage(
            of: fixture.descriptor,
            in: fixture.paths
        )

        XCTAssertTrue(usage.isInstalled)
        XCTAssertEqual(usage.logicalBytes, 8)
        XCTAssertGreaterThanOrEqual(usage.allocatedBytes, 8)
        XCTAssertEqual(usage.regularFileCount, 2)
    }

    func testKnownProfileEvaluatesDiskAndPhysicalMemory() async throws {
        let profile = try ModelResourceProfile(
            downloadBytes: 1_000,
            installedBytes: 1_500,
            peakMemoryBytes: 4_000,
            evidence: .measured(description: "Test fixture measurement")
        )
        let fixture = try makeDescriptor(profile: profile)
        let evaluator = ModelResourceSafetyEvaluator(
            capacityProvider: FixedCapacityProvider(bytes: 10_000),
            memoryProvider: FixedMemoryProvider(bytes: 10_000),
            policy: ModelResourceSafetyPolicy(
                minimumFreeDiskReserveBytes: 2_000,
                minimumPhysicalMemoryReserveBytes: 1_000,
                maximumPhysicalMemoryFraction: 0.5
            )
        )

        let evaluation = await evaluator.evaluate(
            fixture.descriptor,
            in: fixture.paths
        )

        XCTAssertEqual(
            evaluation.disk,
            .sufficient(requiredBytes: 3_500, availableBytes: 10_000)
        )
        XCTAssertEqual(
            evaluation.memory,
            .sufficient(
                requiredBytes: 4_000,
                budgetBytes: 5_000,
                physicalBytes: 10_000
            )
        )
        XCTAssertTrue(evaluation.allowsInstallationAndLoading)
        XCTAssertNil(evaluation.installationBlocker)
        XCTAssertNil(evaluation.loadingBlocker)
    }

    func testUnsafeAndUnknownProfilesFailClosed() async throws {
        let profile = try ModelResourceProfile(
            downloadBytes: 5_000,
            installedBytes: 6_000,
            peakMemoryBytes: 8_000,
            evidence: .upstream(description: "Primary source fixture")
        )
        let known = try makeDescriptor(profile: profile)
        let evaluator = ModelResourceSafetyEvaluator(
            capacityProvider: FixedCapacityProvider(bytes: 6_500),
            memoryProvider: FixedMemoryProvider(bytes: 10_000),
            policy: ModelResourceSafetyPolicy(
                minimumFreeDiskReserveBytes: 1_000,
                minimumPhysicalMemoryReserveBytes: 1_000,
                maximumPhysicalMemoryFraction: 0.7
            )
        )

        let unsafe = await evaluator.evaluate(
            known.descriptor,
            in: known.paths
        )
        XCTAssertEqual(
            unsafe.disk,
            .insufficient(requiredBytes: 7_000, availableBytes: 6_500)
        )
        XCTAssertEqual(
            unsafe.memory,
            .insufficient(
                requiredBytes: 8_000,
                budgetBytes: 7_000,
                physicalBytes: 10_000
            )
        )
        XCTAssertFalse(unsafe.allowsInstallationAndLoading)
        XCTAssertEqual(
            unsafe.installationBlocker,
            .insufficientDisk(requiredBytes: 7_000, availableBytes: 6_500)
        )
        XCTAssertEqual(
            unsafe.loadingBlocker,
            .insufficientMemory(
                requiredBytes: 8_000,
                budgetBytes: 7_000,
                physicalBytes: 10_000
            )
        )

        let unknown = try makeDescriptor(profile: nil)
        let unknownEvaluation = await evaluator.evaluate(
            unknown.descriptor,
            in: unknown.paths
        )
        XCTAssertEqual(unknownEvaluation.disk, .unknownRequirements)
        XCTAssertEqual(unknownEvaluation.memory, .unknownRequirements)
        XCTAssertFalse(unknownEvaluation.allowsInstallationAndLoading)
        XCTAssertEqual(
            unknownEvaluation.installationBlocker,
            .diskRequirementsUnknown
        )
        XCTAssertEqual(
            unknownEvaluation.loadingBlocker,
            .memoryRequirementsUnknown
        )
    }

    func testResourceProfileRequiresMeasurementsAndEvidence() {
        XCTAssertThrowsError(
            try ModelResourceProfile(
                downloadBytes: 0,
                installedBytes: 1,
                peakMemoryBytes: 1,
                evidence: .measured(description: "Measured")
            )
        )
        XCTAssertThrowsError(
            try ModelResourceProfile(
                downloadBytes: 1,
                installedBytes: 1,
                peakMemoryBytes: 1,
                evidence: .upstream(description: "   ")
            )
        )
    }

    private func makeDescriptor(
        profile: ModelResourceProfile?
    ) throws -> ResourceFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: root.path) else {
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let descriptor = try ModelDescriptor(
            id: ModelIdentifier(rawValue: UUID().uuidString),
            displayName: "Resource test",
            detail: "",
            provider: .whisperKit,
            task: .transcription,
            installationDirectoryName: "resource-test",
            supportedLanguages: ["en"],
            windowGeometry: .init(duration: 30, overlap: 0),
            resourceProfile: profile
        )
        return ResourceFixture(
            descriptor: descriptor,
            paths: ModelStoragePaths(modelsDirectory: root)
        )
    }
}

private struct ResourceFixture {
    let descriptor: ModelDescriptor
    let paths: ModelStoragePaths
}

private struct FixedCapacityProvider: ModelStorageCapacityProviding {
    let bytes: Int64

    func availableCapacity(at _: URL) async -> Int64 {
        bytes
    }
}

private struct FixedMemoryProvider: PhysicalMemoryProviding {
    let bytes: Int64

    func physicalMemoryBytes() async -> Int64 {
        bytes
    }
}
