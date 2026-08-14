@preconcurrency import AppKit
import AudioCapture
import SwiftUI

enum ScribeTypography {
    static let sessionTitle = Font.system(size: 15, weight: .medium)
    static let sessionMetadata = Font.system(size: 12, weight: .regular)
    static let sidebarItem = Font.system(size: 13, weight: .regular)
    static let sidebarSection = Font.system(size: 11, weight: .medium)
    static let transcriptSpeaker = Font.system(size: 11, weight: .medium)
    static let transcriptBody = Font.system(size: 14, weight: .regular)
    static let notesBody = Font.system(size: 15, weight: .regular)
    static let timestamp = Font.system(
        size: 11,
        weight: .regular,
        design: .monospaced
    )
}

enum ScribePalette {
    static let accent = adaptive(light: 0x7C5CE0, dark: 0x9A7FE8)
    static let others = adaptive(light: 0x14919B, dark: 0x32AAB2)

    /// Idle: the control is ready to start a recording.
    static let readyToRecord = adaptive(light: 0x1E8E3E, dark: 0x37C464)

    /// Live: a recording is running. Deliberately the one red in the app, so
    /// it never competes with a speaker colour for meaning.
    static let recordingActive = adaptive(light: 0xD93025, dark: 0xF2544B)

    static let speakers: [Color] = [
        accent,
        others,
        adaptive(light: 0x2B6FAE, dark: 0x62A0D2),
        adaptive(light: 0x9B6512, dark: 0xD2A24F),
        adaptive(light: 0xA94D67, dark: 0xDE7892),
        adaptive(light: 0x4F5FAF, dark: 0x8492D9),
        adaptive(light: 0x9B543A, dark: 0xD58466),
        adaptive(light: 0x627A27, dark: 0x9CB65B)
    ]

    static func speaker(
        id: String,
        source: AudioSource
    ) -> Color {
        if id == "source.microphone" { return accent }
        if id == "source.system" { return others }
        if source == .microphone { return accent }
        let index = RecordingViewPresentation.paletteIndex(
            for: id,
            paletteCount: speakers.count
        )
        return speakers[index]
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return nsColor(match == .darkAqua ? dark : light)
        })
    }

    private static func nsColor(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The drifting two-wave ASCII field, without any surrounding copy.
///
/// Lives on its own so it can appear both in the empty library and in the
/// transcript rail while the first text is still being produced.
struct AsciiWaveformView: View {
    var columns = 104
    var rows = 17
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion || controlActiveState != .key
            )) { context in
                let time = reduceMotion
                    ? 0
                    : context.date.timeIntervalSinceReferenceDate * 0.3
                ZStack {
                    wave(
                        time: time,
                        seed: 0.8,
                        scale: 0.88,
                        color: ScribePalette.accent,
                        size: geometry.size
                    )
                    wave(
                        time: time,
                        seed: 4.2,
                        scale: 0.62,
                        color: ScribePalette.others,
                        size: geometry.size
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(Double(columns) / Double(rows), contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func wave(
        time: TimeInterval,
        seed: Double,
        scale: Double,
        color: Color,
        size: CGSize
    ) -> some View {
        let characterWidth = size.width / Double(columns)
        let rowHeight = size.height / Double(rows)
        let fontSize = max(4, min(11, min(characterWidth * 1.55, rowHeight)))
        return Text(verbatim: grid(time: time, seed: seed, scale: scale))
            .font(.system(
                size: fontSize,
                weight: .regular,
                design: .monospaced
            ))
            .lineSpacing(-fontSize * 0.12)
            .foregroundStyle(color)
            .fixedSize()
            .minimumScaleFactor(0.5)
    }

    private func grid(
        time: TimeInterval,
        seed: Double,
        scale: Double
    ) -> String {
        let ramp = Array(" .:-=+*#@")
        let middle = Double(rows - 1) / 2
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            var line = ""
            line.reserveCapacity(columns)
            for column in 0..<columns {
                let x = Double(column)
                let a = sin(x * 0.055 + time * 0.9 + seed) * 0.55
                let b = sin(x * 0.021 - time * 0.55 + seed * 2.1) * 0.30
                let c = sin(x * 0.13 + time * 1.7 + seed * 0.7) * 0.15
                let envelope = 0.55
                    + 0.45 * sin(x * 0.014 - time * 0.35 + seed)
                let y = middle
                    + (a + b + c) * envelope * middle * scale
                let density = max(0, 1 - abs(Double(row) - y) / 2.6)
                let index = min(
                    ramp.count - 1,
                    max(0, Int((density * Double(ramp.count - 1)).rounded()))
                )
                line.append(ramp[index])
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

struct EmptyLibraryWaveformView: View {
    let sessionCount: Int

    var body: some View {
        VStack(spacing: 18) {
            AsciiWaveformView()
                .frame(maxWidth: 820)

            Text(ScribeCopy.Shell.sessionCount(sessionCount))
                .font(ScribeTypography.sessionMetadata)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ScribeCopy.Shell.sessionCount(sessionCount))
    }
}
