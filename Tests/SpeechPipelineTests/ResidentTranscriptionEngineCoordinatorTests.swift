import AudioCapture
@testable import SpeechPipeline
import XCTest

final class ResidentTranscriptionEngineCoordinatorTests: XCTestCase {
    func testSwitchUnloadsPreviousEngineBeforePreparingNext() async throws {
        let events = EngineEventRecorder()
        let coordinator = ResidentTranscriptionEngineCoordinator()
        let first = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(identifier: "first", events: events),
            coordinator: coordinator
        )
        let second = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(identifier: "second", events: events),
            coordinator: coordinator
        )

        try await first.prepare()
        try await second.prepare()

        let switchEvents = await events.values
        let residentState = await coordinator.state
        XCTAssertEqual(
            switchEvents,
            ["first.prepare", "first.unload", "second.prepare"]
        )
        XCTAssertEqual(
            residentState,
            .resident(identifier: "second")
        )

        await first.unload()
        let stateAfterStaleUnload = await coordinator.state
        XCTAssertEqual(
            stateAfterStaleUnload,
            .resident(identifier: "second")
        )
        await second.unload()
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testStaleEngineCannotTranscribeOrUnloadNewResident() async throws {
        let events = EngineEventRecorder()
        let coordinator = ResidentTranscriptionEngineCoordinator()
        let first = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(identifier: "first", events: events),
            coordinator: coordinator
        )
        let second = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(identifier: "second", events: events),
            coordinator: coordinator
        )
        try await first.prepare()
        try await second.prepare()

        do {
            _ = try await first.transcribe(Self.chunk)
            XCTFail("Expected the first model lease to be invalidated.")
        } catch let error as ResidentTranscriptionEngineError {
            XCTAssertEqual(
                error,
                .leaseInvalidated(
                    requestedIdentifier: "first",
                    residentIdentifier: "second"
                )
            )
        }

        await first.unload()
        _ = try await second.transcribe(Self.chunk)
        let residentState = await coordinator.state
        let switchEvents = await events.values
        XCTAssertEqual(residentState, .resident(identifier: "second"))
        XCTAssertEqual(
            switchEvents,
            [
                "first.prepare", "first.unload", "second.prepare",
                "second.transcribe",
            ]
        )
    }

    func testPreviouslyInvalidatedWrapperCanSwitchBack() async throws {
        let events = EngineEventRecorder()
        let coordinator = ResidentTranscriptionEngineCoordinator()
        let first = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(identifier: "first", events: events),
            coordinator: coordinator
        )
        let second = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(identifier: "second", events: events),
            coordinator: coordinator
        )
        try await first.prepare()
        try await second.prepare()

        try await first.prepare()

        let state = await coordinator.state
        let switchEvents = await events.values
        XCTAssertEqual(state, .resident(identifier: "first"))
        XCTAssertEqual(
            switchEvents,
            [
                "first.prepare", "first.unload", "second.prepare",
                "second.unload", "first.prepare",
            ]
        )
    }

    func testFailedReplacementLeavesNoResidentAndPreservesCause()
        async throws
    {
        let events = EngineEventRecorder()
        let coordinator = ResidentTranscriptionEngineCoordinator()
        let first = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(identifier: "first", events: events),
            coordinator: coordinator
        )
        let failing = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(
                identifier: "failing",
                events: events,
                prepareError: CoordinatorTestError.prepareFailed
            ),
            coordinator: coordinator
        )
        try await first.prepare()

        do {
            try await failing.prepare()
            XCTFail("Expected replacement preparation to fail.")
        } catch let error as CoordinatorTestError {
            XCTAssertEqual(error, .prepareFailed)
        }

        let failedState = await coordinator.state
        let failureEvents = await events.values
        XCTAssertEqual(
            failedState,
            .failed(identifier: "failing", message: "prepare failed")
        )
        XCTAssertEqual(
            failureEvents,
            [
                "first.prepare", "first.unload", "failing.prepare",
                "failing.unload",
            ]
        )
    }

    func testSwitchDuringInferenceFailsWithoutUnloadingResident() async throws {
        let events = EngineEventRecorder()
        let gate = InferenceGate()
        let coordinator = ResidentTranscriptionEngineCoordinator()
        let first = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(
                identifier: "first",
                events: events,
                inferenceGate: gate
            ),
            coordinator: coordinator
        )
        let second = CoordinatedTranscriptionEngine(
            engine: CoordinatorMockEngine(identifier: "second", events: events),
            coordinator: coordinator
        )
        try await first.prepare()
        async let inference = first.transcribe(Self.chunk)
        await gate.waitUntilStarted()

        do {
            try await second.prepare()
            XCTFail("Expected the active inference to prevent switching.")
        } catch let error as ResidentTranscriptionEngineError {
            XCTAssertEqual(error, .engineInUse(identifier: "first"))
        }
        let blockedSwitchEvents = await events.values
        XCTAssertEqual(
            blockedSwitchEvents,
            ["first.prepare", "first.transcribe"]
        )

        await gate.finish()
        _ = try await inference
        try await second.prepare()
        let completedSwitchEvents = await events.values
        XCTAssertEqual(
            completedSwitchEvents,
            [
                "first.prepare", "first.transcribe", "first.unload",
                "second.prepare",
            ]
        )
    }

    private static let chunk = AudioChunk(
        samples: [0],
        startTime: 0,
        source: .microphone
    )
}

private actor EngineEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor InferenceGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func begin() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { finishContinuation = $0 }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor CoordinatorMockEngine: TranscriptionEngine {
    nonisolated let identifier: String
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]

    private let events: EngineEventRecorder
    private let prepareError: CoordinatorTestError?
    private let inferenceGate: InferenceGate?

    init(
        identifier: String,
        events: EngineEventRecorder,
        prepareError: CoordinatorTestError? = nil,
        inferenceGate: InferenceGate? = nil
    ) {
        self.identifier = identifier
        self.events = events
        self.prepareError = prepareError
        self.inferenceGate = inferenceGate
    }

    func prepare() async throws {
        await events.append("\(identifier).prepare")
        if let prepareError { throw prepareError }
    }

    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSegment] {
        await events.append("\(identifier).transcribe")
        if let inferenceGate { await inferenceGate.begin() }
        return [
            TranscriptSegment(
                text: identifier,
                startTime: chunk.startTime,
                endTime: chunk.startTime + chunk.duration,
                source: chunk.source
            ),
        ]
    }

    func finish() -> [TranscriptSegment] { [] }

    func unload() async {
        await events.append("\(identifier).unload")
    }
}

private enum CoordinatorTestError: Error, Equatable, LocalizedError {
    case prepareFailed

    var errorDescription: String? { "prepare failed" }
}
