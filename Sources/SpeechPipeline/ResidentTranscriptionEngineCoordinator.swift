import Foundation

public enum ResidentTranscriptionEngineState: Equatable, Sendable {
    case idle
    case unloading(identifier: String)
    case preparing(identifier: String)
    case resident(identifier: String)
    case failed(identifier: String, message: String)
}

public enum ResidentTranscriptionEngineError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case transitionInProgress
    case engineInUse(identifier: String)
    case leaseInvalidated(
        requestedIdentifier: String,
        residentIdentifier: String?
    )

    public var errorDescription: String? {
        switch self {
        case .transitionInProgress:
            "A transcription model is already loading or unloading."
        case let .engineInUse(identifier):
            "Transcription model \(identifier) is processing audio and cannot be switched yet."
        case let .leaseInvalidated(requested, resident):
            if let resident {
                "Transcription model \(requested) is no longer resident; \(resident) is loaded instead."
            } else {
                "Transcription model \(requested) is no longer resident."
            }
        }
    }
}

/// Owns the only prepared ASR engine in the process.
///
/// Pipelines use `CoordinatedTranscriptionEngine` rather than calling these
/// methods directly. The coordinator serializes model transitions, prevents a
/// switch while inference is in flight, and invalidates old wrappers after a
/// successful switch.
public actor ResidentTranscriptionEngineCoordinator {
    public private(set) var state: ResidentTranscriptionEngineState = .idle

    fileprivate struct Lease: Equatable, Sendable {
        let identifier: String
        let generation: UInt64
    }

    private struct Resident: Sendable {
        let lease: Lease
        let engine: any TranscriptionEngine
    }

    private var resident: Resident?
    private var generation: UInt64 = 0
    private var transitionInProgress = false
    private var inferenceInProgress = false
    private var releaseRequested = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    fileprivate func activate(
        _ engine: any TranscriptionEngine
    ) async throws -> Lease {
        guard !transitionInProgress else {
            throw ResidentTranscriptionEngineError.transitionInProgress
        }
        if inferenceInProgress, let resident {
            throw ResidentTranscriptionEngineError.engineInUse(
                identifier: resident.lease.identifier
            )
        }

        transitionInProgress = true
        if let current = resident {
            state = .unloading(identifier: current.lease.identifier)
            await current.engine.unload()
            resident = nil
        }

        state = .preparing(identifier: engine.identifier)
        do {
            try await engine.prepare()
            generation &+= 1
            let lease = Lease(
                identifier: engine.identifier,
                generation: generation
            )
            resident = Resident(lease: lease, engine: engine)
            state = .resident(identifier: engine.identifier)
            transitionInProgress = false
            return lease
        } catch {
            await engine.unload()
            resident = nil
            state = .failed(
                identifier: engine.identifier,
                message: error.localizedDescription
            )
            transitionInProgress = false
            throw error
        }
    }

    fileprivate func transcribe(
        lease: Lease,
        chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        let engine = try beginInference(for: lease)
        do {
            let output = try await engine.transcribe(chunk)
            await completeInference(for: lease)
            return output
        } catch {
            await completeInference(for: lease)
            throw error
        }
    }

    fileprivate func finish(
        lease: Lease
    ) async throws -> [TranscriptSegment] {
        let engine = try beginInference(for: lease)
        do {
            let output = try await engine.finish()
            await completeInference(for: lease)
            return output
        } catch {
            await completeInference(for: lease)
            throw error
        }
    }

    fileprivate func release(_ lease: Lease) async {
        guard resident?.lease == lease else { return }
        if transitionInProgress {
            return
        }
        if inferenceInProgress {
            await withCheckedContinuation { continuation in
                releaseRequested = true
                releaseWaiters.append(continuation)
            }
            return
        }
        await unloadResident()
    }

    fileprivate func isCurrent(_ lease: Lease) -> Bool {
        !transitionInProgress && resident?.lease == lease
    }

    private func beginInference(
        for lease: Lease
    ) throws -> any TranscriptionEngine {
        guard !transitionInProgress else {
            throw ResidentTranscriptionEngineError.transitionInProgress
        }
        guard let resident, resident.lease == lease else {
            throw invalidLeaseError(for: lease)
        }
        guard !inferenceInProgress else {
            throw ResidentTranscriptionEngineError.engineInUse(
                identifier: resident.lease.identifier
            )
        }
        inferenceInProgress = true
        return resident.engine
    }

    private func completeInference(for lease: Lease) async {
        inferenceInProgress = false
        guard releaseRequested, resident?.lease == lease else { return }
        await unloadResident()
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        releaseRequested = false
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func unloadResident() async {
        guard let current = resident else {
            state = .idle
            return
        }
        transitionInProgress = true
        state = .unloading(identifier: current.lease.identifier)
        await current.engine.unload()
        resident = nil
        transitionInProgress = false
        state = .idle
    }

    private func invalidLeaseError(
        for lease: Lease
    ) -> ResidentTranscriptionEngineError {
        .leaseInvalidated(
            requestedIdentifier: lease.identifier,
            residentIdentifier: resident?.lease.identifier
        )
    }
}

/// A `TranscriptionEngine` facade whose lifecycle is controlled by one shared
/// `ResidentTranscriptionEngineCoordinator`.
public actor CoordinatedTranscriptionEngine: TranscriptionEngine {
    public nonisolated let identifier: String
    public nonisolated let supportsStreaming: Bool
    public nonisolated let requiresNetwork: Bool
    public nonisolated let supportedLanguages: [String]
    public nonisolated let preferredWindowDuration: TimeInterval
    public nonisolated let preferredOverlap: TimeInterval

    private let engine: any TranscriptionEngine
    private let coordinator: ResidentTranscriptionEngineCoordinator
    private var lease: ResidentTranscriptionEngineCoordinator.Lease?

    public init(
        engine: any TranscriptionEngine,
        coordinator: ResidentTranscriptionEngineCoordinator
    ) {
        self.engine = engine
        self.coordinator = coordinator
        self.identifier = engine.identifier
        self.supportsStreaming = engine.supportsStreaming
        self.requiresNetwork = engine.requiresNetwork
        self.supportedLanguages = engine.supportedLanguages
        self.preferredWindowDuration = engine.preferredWindowDuration
        self.preferredOverlap = engine.preferredOverlap
    }

    public func prepare() async throws {
        if let lease, await coordinator.isCurrent(lease) {
            return
        }
        lease = nil
        lease = try await coordinator.activate(engine)
    }

    public func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        guard let lease else {
            throw ResidentTranscriptionEngineError.leaseInvalidated(
                requestedIdentifier: identifier,
                residentIdentifier: await coordinator.residentIdentifier
            )
        }
        return try await coordinator.transcribe(
            lease: lease,
            chunk: chunk
        )
    }

    public func finish() async throws -> [TranscriptSegment] {
        guard let lease else {
            throw ResidentTranscriptionEngineError.leaseInvalidated(
                requestedIdentifier: identifier,
                residentIdentifier: await coordinator.residentIdentifier
            )
        }
        return try await coordinator.finish(lease: lease)
    }

    public func unload() async {
        guard let lease else { return }
        self.lease = nil
        await coordinator.release(lease)
    }
}

private extension ResidentTranscriptionEngineCoordinator {
    var residentIdentifier: String? {
        resident?.lease.identifier
    }
}
