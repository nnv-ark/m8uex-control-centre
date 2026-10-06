import SwiftUI

// MARK: - Diagnostics

/// The view you open when MIDI is misbehaving: per-port health, malformed data,
/// clock stability and the exact CoreMIDI topology behind each socket.
public struct DiagnosticsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var engine: MIDIEngine

    public init(engine: MIDIEngine) {
        self.engine = engine
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                systemPanel
                if engine.hardwareOnline || !engine.m8uPorts.isEmpty {
                    portHealthPanel
                }
                clockPanel
                routingPanel
                hardwareLimitsPanel
            }
            .padding(16)
        }
        .background(Palette.windowBackground)
    }

    // MARK: System

    private var systemPanel: some View {
        Panel(title: "System") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Status", value: engine.statusLine)
                LabeledContent("Interfaces found", value: "\(engine.connectedUnitCount)")
                LabeledContent("M8U eX sockets", value: "\(engine.m8uPorts.count)")
                LabeledContent("Endpoints tracked", value: "\(engine.ports.count)")
                LabeledContent("Active routes", value: "\(engine.routes.filter(\.isEnabled).count)")
                LabeledContent("Midnight Protocol", value: "CoreMIDI MIDI 1.0, class compliant")
                LabeledContent("Monitor log", value: "\(engine.monitorEvents.count) events")
            }
            .font(.system(size: 11))

            HStack(spacing: 8) {
                Button {
                    engine.refresh()
                } label: {
                    Label("Rescan MIDI devices", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Button {
                    engine.resetStatistics()
                    engine.clearMonitor()
                    state.show(toast: "Counters reset")
                } label: {
                    Label("Reset counters", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Per-port health

    private var portHealthPanel: some View {
        Panel(
            title: "Port health",
            subtitle: "counters, peak rates and malformed data per socket"
        ) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("PORT").frame(width: 120, alignment: .leading)
                    Text("DIR").frame(width: 40, alignment: .leading)
                    Text("RATE").frame(width: 70, alignment: .trailing)
                    Text("PEAK").frame(width: 70, alignment: .trailing)
                    Text("MESSAGES").frame(width: 80, alignment: .trailing)
                    Text("DATA").frame(width: 80, alignment: .trailing)
                    Text("MALFORMED").frame(width: 80, alignment: .trailing)
                    Spacer()
                }
                .font(.system(size: 9, weight: .semibold))
                .mutedText()
                .padding(.vertical, 3)

                Divider()

                ForEach(engine.m8uPorts) { port in
                    let stats = engine.portStats[port.id]
                    HStack(spacing: 6) {
                        HStack(spacing: 5) {
                            LED(direction: port.direction, size: 7)
                            Text(state.label(for: port.id))
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .frame(width: 120, alignment: .leading)

                        Text(directionAbbreviation(port.direction))
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.color(for: port.direction))
                            .frame(width: 40, alignment: .leading)

                        Text(Format.rate(stats?.messagesPerSecond ?? 0))
                            .frame(width: 70, alignment: .trailing)
                        Text(Format.rate(stats?.peakMessagesPerSecond ?? 0))
                            .frame(width: 70, alignment: .trailing)
                        Text(Format.count(stats?.messageCount ?? 0))
                            .frame(width: 80, alignment: .trailing)
                        Text(Format.bytes(stats?.byteCount ?? 0))
                            .frame(width: 80, alignment: .trailing)
                        Text("\(stats?.anomalyCount ?? 0)")
                            .foregroundStyle((stats?.anomalyCount ?? 0) > 0 ? Palette.output : Color.secondary)
                            .frame(width: 80, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.vertical, 2)
                    Divider().opacity(0.2)
                }
            }
        }
    }

    private func directionAbbreviation(_ direction: PortDirection) -> String {
        switch direction {
        case .input: return "IN"
        case .output: return "OUT"
        case .idle: return "—"
        }
    }

    // MARK: Clock

    private var clockPanel: some View {
        Panel(
            title: "MIDI clock",
            subtitle: "clock is the most timing-sensitive thing on the wire"
        ) {
            let clockPorts = engine.m8uPorts.filter { (engine.portStats[$0.id]?.clockCount ?? 0) > 0 }
            return VStack(alignment: .leading, spacing: 8) {
                if clockPorts.isEmpty {
                    Text("No MIDI clock is currently flowing on any port.")
                        .font(.system(size: 11))
                        .mutedText()
                } else {
                    ForEach(clockPorts) { port in
                        let stats = engine.portStats[port.id]
                        HStack(spacing: 10) {
                            LED(direction: port.direction, size: 8)
                            Text(state.label(for: port.id))
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 120, alignment: .leading)
                            Text("\(Format.count(stats?.clockCount ?? 0)) pulses")
                                .font(.system(size: 10, design: .monospaced))
                                .mutedText()
                            Spacer()
                            if let bpm = tempo(for: stats) {
                                Text(String(format: "≈%.1f BPM", bpm))
                                    .font(.system(size: 11, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                    }
                    Text("MIDI clock is 24 pulses per quarter note, so a steady 24 pulses per second is 60 BPM. "
                         + "Estimates use each port's clock share of its total traffic.")
                        .font(.system(size: 9))
                        .faintText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func tempo(for stats: PortStats?) -> Double? {
        guard let stats, stats.messageCount > 0, stats.clockCount > 0, stats.messagesPerSecond > 1 else { return nil }
        let share = Double(stats.clockCount) / Double(stats.messageCount)
        let clockRate = stats.messagesPerSecond * share
        guard clockRate > 1 else { return nil }
        return clockRate / 24.0 * 60.0
    }

    // MARK: Routing

    private var routingPanel: some View {
        Panel(
            title: "Routing",
            subtitle: "\(engine.routes.count) routes defined"
        ) {
            VStack(alignment: .leading, spacing: 4) {
                if engine.routes.isEmpty {
                    Text("No routes are defined. The interface passes nothing between its own sockets "
                         + "while it is connected to the computer — that is what the hardware's standalone "
                         + "thru and merge modes are for.")
                        .font(.system(size: 11))
                        .mutedText()
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(engine.routes) { route in
                        HStack(spacing: 8) {
                            Image(systemName: route.isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 10))
                                .foregroundStyle(route.isEnabled ? Palette.input : Color.secondary)
                            Text("\(state.label(for: route.sourcePortID)) → \(state.label(for: route.destinationPortID))")
                                .font(.system(size: 11))
                            Spacer()
                            Text(route.channels.label)
                                .font(.system(size: 9))
                                .mutedText()
                            if let summary = route.transform.summary {
                                Text(summary)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Palette.accent)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Hardware limits

    private var hardwareLimitsPanel: some View {
        Panel(
            title: "What this app cannot do",
            subtitle: "honest limits, so you know when to reach for the hardware"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                limitRow(
                    "Standalone modes",
                    detail: "Pass-through, MIDI thru and MIDI merge run in the interface's own firmware and "
                        + "only while no computer is connected. Use the MODE button."
                )
                limitRow(
                    "DIP switches",
                    detail: "Unit A/B addressing, MIDI running status and USB 2.0 legacy mode are physical "
                        + "switches on the underside. They must be set with USB and power disconnected."
                )
                limitRow(
                    "Front-panel LEDs",
                    detail: "The LEDs show the direction the hardware auto-detected. macOS can observe the "
                        + "same thing from traffic, which is what the Dashboard shows, but cannot drive them."
                )
                limitRow(
                    "SysEx in merge mode",
                    detail: "In hardware merge mode only port 1 carries SysEx — a limitation of the merge "
                        + "engine, not of this software."
                )
            }
        }
    }

    private func limitRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .mutedText()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
