import SwiftUI

// MARK: - Monitor

/// A live MIDI monitor across every port at once.
///
/// This is the view that answers "is the interface actually passing this?", and
/// it is the one thing neither the hardware nor ESI's Windows driver gives you.
public struct MonitorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var engine: MIDIEngine
    @State private var directionFilter: DirectionFilter = .all
    @State private var portFilter: MIDIPort.ID?
    @State private var showsHex = true

    public init(engine: MIDIEngine) {
        self.engine = engine
    }

    private enum DirectionFilter: String, CaseIterable, Identifiable {
        case all, input, output
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Both"
            case .input: return "Incoming"
            case .output: return "Outgoing"
            }
        }
    }

    private var filteredEvents: [MonitoredEvent] {
        let needle = state.monitorFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return engine.monitorEvents.filter { event in
            switch directionFilter {
            case .input where event.direction != .input: return false
            case .output where event.direction != .output: return false
            default: break
            }
            if let portFilter, event.portID != portFilter { return false }
            guard !needle.isEmpty else { return true }
            return event.message.summary.lowercased().contains(needle)
                || event.portLabel.lowercased().contains(needle)
                || Format.hex(event.message.bytes).lowercased().contains(needle)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if engine.monitorEvents.isEmpty {
                EmptyStateView(
                    symbol: "waveform.path.ecg",
                    title: "No MIDI yet",
                    message: engine.hardwareOnline
                        ? "Play something on a connected keyboard and the traffic will appear here, port by port."
                        : "Connect the M8U eX and play a note — every message on all 16 sockets shows up here."
                )
            } else {
                eventList
            }
        }
        .background(Palette.windowBackground)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Monitor")
                    .font(.system(size: 13, weight: .semibold))

                TextField("Filter by note, CC, hex, port…", text: $state.monitorFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 280)

                Picker("", selection: $directionFilter) {
                    ForEach(DirectionFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
                .controlSize(.small)

                Picker("", selection: $portFilter) {
                    Text("All ports").tag(MIDIPort.ID?.none)
                    ForEach(engine.ports) { port in
                        Text(state.label(for: port.id)).tag(MIDIPort.ID?.some(port.id))
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .controlSize(.small)

                Spacer()

                Toggle("Hex", isOn: $showsHex)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Show the raw bytes alongside the decoded message")

                Button(engine.monitorEnabled ? "Pause" : "Resume") {
                    engine.monitorEnabled.toggle()
                }
                .controlSize(.small)

                Button("Clear") {
                    engine.clearMonitor()
                }
                .controlSize(.small)
                .disabled(engine.monitorEvents.isEmpty)
            }

            HStack(spacing: 12) {
                Text("\(filteredEvents.count) of \(engine.monitorEvents.count) events")
                    .font(.system(size: 10))
                    .mutedText()
                if !engine.monitorEnabled {
                    Label("Logging paused", systemImage: "pause.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("Newest at the bottom · capped at \(engine.monitorCapacity) events")
                    .font(.system(size: 9))
                    .faintText()
            }
        }
        .padding(12)
    }

    // MARK: Event list

    private var eventList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEvents) { event in
                        MonitorRow(event: event, showsHex: showsHex)
                            .id(event.id)
                        Divider().opacity(0.15)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .onChange(of: engine.monitorEvents.count) { _, _ in
                // Follow the tail, the way a monitor is expected to behave.
                if let last = filteredEvents.last {
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Monitor row

struct MonitorRow: View {
    let event: MonitoredEvent
    let showsHex: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Format.elapsed(event.seconds))
                .font(.system(size: 10, design: .monospaced))
                .faintText()
                .frame(width: 78, alignment: .leading)

            HStack(spacing: 4) {
                Image(systemName: event.direction == .input ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 8))
                Text(event.portLabel)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.color(for: event.direction))
            .frame(width: 130, alignment: .leading)

            Text(event.message.summary)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsHex {
                Text(Format.hex(event.message.bytes))
                    .font(.system(size: 9, design: .monospaced))
                    .faintText()
                    .lineLimit(1)
                    .frame(width: 190, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}
