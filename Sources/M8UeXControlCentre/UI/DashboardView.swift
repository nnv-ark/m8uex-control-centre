import SwiftUI
import Combine

// MARK: - Dashboard

/// The live view of the interface: one tile per MIDI socket, mirroring the
/// front-panel LEDs, plus the clock and throughput totals the hardware cannot
/// show you.
public struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var engine: MIDIEngine
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    public init(engine: MIDIEngine) {
        self.engine = engine
    }

    private var hardwarePorts: [MIDIPort] {
        engine.ports.filter { $0.isM8UPhysical }.sorted { $0.sortKey < $1.sortKey }
    }

    /// Physical ports grouped by the interface they belong to, in the order the
    /// interfaces sort.
    ///
    /// Grouping matters once two units are connected: an M4U eX and an M8U eX both
    /// number their sockets from 1, so a flat grid interleaves them and a tile
    /// labelled "Port 1" is ambiguous. Grouping also keeps each unit's sockets in
    /// the 1, 2, 3… order printed on its own front panel.
    private var hardwarePortsByUnit: [(unit: String, ports: [MIDIPort])] {
        var order: [String] = []
        var grouped: [String: [MIDIPort]] = [:]
        for port in hardwarePorts {
            let unit = port.unitName ?? "MIDI interface"
            if grouped[unit] == nil { order.append(unit) }
            grouped[unit, default: []].append(port)
        }
        return order.map { unit in
            let sockets = (grouped[unit] ?? []).sorted { ($0.m8uIndex ?? 0) < ($1.m8uIndex ?? 0) }
            return (unit, sockets)
        }
    }

    /// External endpoints, empty unless the user has asked to see them.
    ///
    /// CoreMIDI publishes every virtual endpoint on the system, which for this
    /// machine means twelve "SSL V-MIDI" ports from a driver whose hardware is not
    /// connected. They are routable but irrelevant here, so they stay out of the
    /// way by default.
    private var otherPorts: [MIDIPort] {
        guard state.showsExternalEndpoints else { return [] }
        return engine.ports.filter { !$0.isM8UPhysical }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusHeader

                if hardwarePorts.isEmpty {
                    hardwareMissing
                } else {
                    ForEach(hardwarePortsByUnit, id: \.unit) { group in
                        Panel(
                            title: group.unit,
                            subtitle: "\(group.ports.count) sockets · green = input, red = output, as the front panel shows it"
                        ) {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 10), count: 4),
                                spacing: 10
                            ) {
                                ForEach(group.ports) { port in
                                    PortTile(
                                        port: port,
                                        stats: engine.portStats[port.id],
                                        level: engine.portLevels[port.id] ?? 0,
                                        peak: engine.portPeaks[port.id] ?? 0,
                                        // The panel heading names the interface, so
                                        // the tile itself can stay compact.
                                        label: state.compactLabel(for: port.id),
                                        fullLabel: state.label(for: port.id),
                                        isSelected: state.selectedPortID == port.id
                                    )
                                    .onTapGesture {
                                        state.selectedPortID = port.id
                                        state.section = .patchbay
                                    }
                                }
                            }
                        }
                    }
                }

                activitySummary

                if state.showsExternalEndpoints, !otherPorts.isEmpty {
                    Panel(
                        title: "Other MIDI endpoints",
                        subtitle: "everything else CoreMIDI sees, routable in the Patchbay"
                    ) {
                        VStack(spacing: 4) {
                            ForEach(otherPorts.prefix(12)) { port in
                                OtherPortRow(
                                    port: port,
                                    stats: engine.portStats[port.id],
                                    level: engine.portLevels[port.id] ?? 0
                                )
                            }
                            if otherPorts.count > 12 {
                                Text("and \(otherPorts.count - 12) more…")
                                    .font(.caption)
                                    .mutedText()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                if state.hiddenExternalPortCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                        Text("\(state.hiddenExternalPortCount) external MIDI endpoints hidden")
                        Button("Show") { state.showsExternalEndpoints = true }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 10))
                    .faintText()
                }

                if !engine.issues.isEmpty {
                    Panel(title: "Notices") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(engine.issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Palette.windowBackground)
        .onReceive(ticker) { value in now = value }
    }

    // MARK: Header

    private var statusHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(engine.hardwareOnline ? Palette.input : Palette.output)
                    .frame(width: 11, height: 11)
                    .shadow(color: (engine.hardwareOnline ? Palette.input : Palette.output).opacity(0.7), radius: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.statusLine)
                        .font(.system(size: 14, weight: .semibold))
                    Text(idleDescription)
                        .font(.system(size: 10))
                        .mutedText()
                }
            }

            Spacer()

            HStack(spacing: 22) {
                StatBlock("Routed", value: "\(activeRouteCount)", tint: Palette.accent)
                StatBlock("Throughput", value: Format.rate(totalRate))
                StatBlock("Messages", value: Format.count(engine.totalMessages))
                StatBlock(
                    "Dropped",
                    value: Format.count(engine.totalDropped),
                    tint: engine.totalDropped > 0 ? Palette.output : .secondary
                )
            }
            .frame(maxWidth: 460)

            Button {
                engine.refresh()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Ask CoreMIDI to rediscover MIDI devices")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.stroke.opacity(0.5)))
    }

    private var activeRouteCount: Int {
        engine.routes.filter(\.isEnabled).count
    }

    private var totalRate: Double {
        engine.portStats.values.reduce(0) { $0 + $1.messagesPerSecond }
    }

    private var idleDescription: String {
        guard let last = engine.portStats.values.map(\.lastMessageAt).max(), last > 0 else {
            return "No MIDI seen yet"
        }
        let delta = MIDITime.seconds(MIDITime.hostTime() &- last)
        if delta < 1 { return "MIDI arriving now" }
        if delta < 60 { return "Last message \(Int(delta))s ago" }
        return "Last message \(Int(delta / 60))m ago"
    }

    // MARK: Hardware missing

    private var hardwareMissing: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    engine.connectedUnitCount > 0
                        ? "The interface is remembered but not currently connected"
                        : "No M8U eX detected",
                    systemImage: "cable.connector.slash"
                )
                .font(.system(size: 13, weight: .semibold))

                Text("Plug the interface into USB. It is class compliant, so no driver is needed — "
                     + "macOS will publish all 16 ports by itself and they will appear here automatically.")
                    .font(.callout)
                    .mutedText()
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Worth checking")
                        .font(.system(size: 11, weight: .semibold))
                    Label("DIP switch 3 ON enables USB 3.0 high-performance mode, which is recommended on current macOS.", systemImage: "switch.2")
                    Label("DIP switch 1 sets unit A or B when running more than one interface.", systemImage: "switch.2")
                    Label("The MODE button and the DIP switches are hardware only — macOS cannot read or change them.", systemImage: "hand.raised")
                }
                .font(.caption)
                .mutedText()
            }
        }
    }

    // MARK: Total activity

    private var activitySummary: some View {
        Panel(
            title: "Activity",
            subtitle: engine.monitorEnabled ? "live totals across every port" : "monitor logging is off"
        ) {
            let stats = engine.portStats.values
            let clock = stats.reduce(UInt64(0)) { $0 + $1.clockCount }
            let notes = stats.reduce(UInt64(0)) { $0 + $1.noteOnCount + $1.noteOffCount }
            let cc = stats.reduce(UInt64(0)) { $0 + $1.controlChangeCount }
            let sysEx = stats.reduce(UInt64(0)) { $0 + $1.sysExCount }
            let anomalies = stats.reduce(UInt64(0)) { $0 + $1.anomalyCount }
            let bytes = stats.reduce(UInt64(0)) { $0 + $1.byteCount }

            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    StatBlock("Notes", value: Format.count(notes))
                    StatBlock("Control changes", value: Format.count(cc))
                    StatBlock("Clock", value: Format.count(clock))
                    StatBlock("SysEx", value: Format.count(sysEx))
                    StatBlock("Data", value: Format.bytes(bytes))
                    StatBlock(
                        "Malformed",
                        value: Format.count(anomalies),
                        tint: anomalies > 0 ? .orange : .secondary
                    )
                }

                if clock > 0 {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let rate = engine.portStats.values.reduce(0.0) { $0 + $1.messagesPerSecond }
                        let bpm = estimatedTempo
                        HStack(spacing: 6) {
                            Image(systemName: "metronome")
                                .mutedText()
                            Text(bpm.map { "Estimated tempo \(String(format: "%.1f", $0)) BPM from MIDI clock" }
                                 ?? "MIDI clock present")
                                .font(.caption)
                                .mutedText()
                            Spacer()
                            Text(Format.rate(rate))
                                .font(.caption.monospacedDigit())
                                .mutedText()
                        }
                    }
                }
            }
        }
    }

    /// MIDI clock runs at 24 pulses per quarter note, so 24 clock messages per
    /// second equals 60 BPM. Derived from the observed clock rate.
    private var estimatedTempo: Double? {
        // Clock messages arrive at a steady 24 ppqn, so rather than trusting the
        // aggregate (which note traffic inflates) we look at the busiest clock port.
        let clockRates = engine.ports.compactMap { port -> Double? in
            guard let stats = engine.portStats[port.id], stats.clockCount > 0 else { return nil }
            return stats.messagesPerSecond
        }
        guard let busiest = clockRates.max(), busiest > 1 else { return nil }
        // messagesPerSecond counts every message kind, so scale by the clock share
        // of that port's traffic to avoid reporting nonsense on a busy port.
        let portClockShare = engine.ports.compactMap { port -> Double? in
            guard let stats = engine.portStats[port.id], stats.messageCount > 0, stats.clockCount > 0 else { return nil }
            let share = Double(stats.clockCount) / Double(stats.messageCount)
            return stats.messagesPerSecond * share
        }.max() ?? busiest
        return portClockShare / 24.0 * 60.0
    }
}

// MARK: - Port tile

/// One socket, drawn to match the front panel: label, LED, live meter and the
/// counters macOS can show that the hardware cannot.
struct PortTile: View {
    let port: MIDIPort
    let stats: PortStats?
    let level: Double
    let peak: Double
    /// Compact name for the tile face; the surrounding panel names the interface.
    let label: String
    /// Fully qualified name, used in the tooltip so it is never ambiguous.
    let fullLabel: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LED(direction: port.direction, size: 9)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(directionText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.color(for: port.direction))
            }

            ActivityMeter(level: level, peak: peak, direction: port.direction)

            HStack(spacing: 8) {
                Text(Format.rate(stats?.messagesPerSecond ?? 0))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 2)
                if let stats, stats.messageCount > 0 {
                    Text("\(Format.count(stats.messageCount)) msg")
                        .font(.system(size: 9))
                        .mutedText()
                        .monospacedDigit()
                } else {
                    Text("idle")
                        .font(.system(size: 9))
                        .faintText()
                }
            }

            ChannelStrip(mask: stats?.activeChannelMask ?? 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Palette.accent.opacity(0.20) : Palette.sunkenFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Palette.accent.opacity(0.8) : Palette.stroke.opacity(0.45),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private var directionText: String {
        switch port.direction {
        case .input: return "IN"
        case .output: return "OUT"
        case .idle: return ""
        }
    }

    private var tooltip: String {
        var lines = ["MIDI \(fullLabel)"]
        switch port.direction {
        case .input: lines.append("Working as an input (front-panel LED green)")
        case .output: lines.append("Working as an output (front-panel LED red)")
        case .idle: lines.append("No traffic yet, direction not known")
        }
        if let stats {
            lines.append("Messages: \(stats.messageCount)")
            lines.append("Notes: \(stats.noteOnCount) on, \(stats.noteOffCount) off")
            lines.append("Peak rate: \(Format.rate(stats.peakMessagesPerSecond))")
            if stats.anomalyCount > 0 { lines.append("Malformed: \(stats.anomalyCount)") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Other endpoint row

struct OtherPortRow: View {
    let port: MIDIPort
    let stats: PortStats?
    let level: Double

    var body: some View {
        HStack(spacing: 10) {
            LED(direction: port.direction, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(port.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(capability)
                        .font(.system(size: 9))
                        .mutedText()
                    if let device = port.source?.deviceName ?? port.destination?.deviceName, device != port.label {
                        Text(device)
                            .font(.system(size: 9))
                            .faintText()
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            ActivityMeter(level: level, peak: 0, direction: port.direction)
                .frame(width: 70)
            Text(Format.rate(stats?.messagesPerSecond ?? 0))
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .mutedText()
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var capability: String {
        let canIn = port.source != nil
        let canOut = port.destination != nil
        if canIn && canOut { return "in + out" }
        if canIn { return "input only" }
        if canOut { return "output only" }
        return "unavailable"
    }
}
