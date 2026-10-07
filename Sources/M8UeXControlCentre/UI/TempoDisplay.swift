import SwiftUI

// MARK: - Tempo display

/// A large readout of the average tempo measured from MIDI clock.
///
/// Deliberately the biggest number on the dashboard: tempo is the one thing you
/// glance at from across a room while playing, so it is sized to be read at a
/// distance rather than to fit tidily into a row of small statistics.
///
/// The figure is a **2-second average** and is computed in the engine from CoreMIDI
/// timestamps, not from repeated UI sampling — see `ClockMonitor`. While no clock is
/// arriving it shows a dash and says so, because a confident "0" would be a lie: the
/// sequencer being stopped is not the same as a tempo of zero.
public struct TempoDisplay: View {
    /// Average BPM over the window, or nil when there is not enough clock.
    public let bpm: Double?
    /// Pulses currently inside the averaging window.
    public let pulseCount: Int
    /// True while clock is arriving.
    public let isRunning: Bool
    /// Window length, shown as a caption so the number is never ambiguous.
    public let window: Double
    /// Name of the socket being listened to, so the source is never in doubt.
    public let sourceName: String

    public init(
        bpm: Double?,
        pulseCount: Int,
        isRunning: Bool,
        window: Double = 2.0,
        sourceName: String = ""
    ) {
        self.bpm = bpm
        self.pulseCount = pulseCount
        self.isRunning = isRunning
        self.window = window
        self.sourceName = sourceName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text("TEMPO")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1.2)
                    .mutedText()
                if !sourceName.isEmpty {
                    Text("from \(sourceName)")
                        .font(.system(size: 10))
                        .faintText()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatted)
                    .font(.system(size: 62, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    // Stop the layout jumping as digits change width.
                    .frame(minWidth: 150, alignment: .leading)
                Text("BPM")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .mutedText()
                    .padding(.bottom, 8)
            }

            Text(caption)
                .font(.system(size: 10))
                .faintText()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whole BPM: tenths would flicker and are not musically meaningful.
    private var formatted: String {
        guard let bpm else { return "—" }
        return String(Int(bpm.rounded()))
    }

    private var tint: Color {
        guard bpm != nil else { return Palette.faintText }
        return isRunning ? Palette.input : Palette.mutedText
    }

    private var caption: String {
        if bpm == nil {
            return isRunning
                ? "Measuring — needs about a second of clock"
                : "No MIDI clock. Start the sequencer to see tempo."
        }
        return String(
            format: "Average over %.0f s · %d pulses · 24 ppqn",
            window, pulseCount
        )
    }
}
