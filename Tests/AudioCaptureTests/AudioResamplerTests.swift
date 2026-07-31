import AudioCapture
import Foundation
import XCTest

final class AudioResamplerTests: XCTestCase {
    func testResamplesKnownSineSweepFrom48kHzTo16kHz() throws {
        let inputRate = 48_000.0
        let outputRate = 16_000.0
        let duration = 0.5
        let inputFrameCount = Int(inputRate * duration)
        let startFrequency = 180.0
        let endFrequency = 3_200.0

        let sweep = (0..<inputFrameCount).map { frame -> Float in
            let time = Double(frame) / inputRate
            let sweepRate = (endFrequency - startFrequency) / duration
            let phase = 2 * Double.pi
                * (startFrequency * time + 0.5 * sweepRate * time * time)
            return Float(0.75 * sin(phase))
        }

        let resampler = try AudioResampler(
            inputSampleRate: inputRate,
            outputSampleRate: outputRate
        )
        let output = try resampler.convert(sweep)

        let expectedFrameCount = Int(outputRate * duration)
        XCTAssertApproximatelyEqual(
            output.count,
            expectedFrameCount,
            accuracy: 64
        )
        XCTAssertTrue(output.allSatisfy { $0.isFinite && (-1...1).contains($0) })

        let rootMeanSquare = sqrt(
            output.reduce(0.0) { $0 + Double($1 * $1) }
                / Double(output.count)
        )
        XCTAssertGreaterThan(rootMeanSquare, 0.45)
        XCTAssertLessThan(rootMeanSquare, 0.60)
    }

    func testEmptyInputProducesEmptyOutput() throws {
        let resampler = try AudioResampler(inputSampleRate: 44_100)
        XCTAssertEqual(try resampler.convert([]), [])
    }

    func testRejectsInvalidSampleRates() {
        XCTAssertThrowsError(try AudioResampler(inputSampleRate: 0))
        XCTAssertThrowsError(
            try AudioResampler(
                inputSampleRate: 48_000,
                outputSampleRate: .infinity
            )
        )
    }
}

private extension XCTestCase {
    func XCTAssertApproximatelyEqual(
        _ expression1: Int,
        _ expression2: Int,
        accuracy: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            abs(expression1 - expression2),
            accuracy,
            file: file,
            line: line
        )
    }
}
