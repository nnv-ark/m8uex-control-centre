import SwiftUI

// MARK: - Port inspector

/// Everything known about one port: its live counters, its statistics and the
/// list of routes touching it.
public struct PortInspectorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var engine: MIDIEngine
    let portID: MIDIPort.ID
    @State private var draftLabel: String = ""
    @State private var isEditingLabel = false

    public init(engine: MIDIEngine, portID: MIDIPort.ID) {
        self.engine = engine
        self.portID = portID
    }

    private var port: MIDIPort? {
        engine.ports.first { $0.id == portID }
    }

    private var stats: PortStats? {
        engine.portStats[portID]
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let port {
                    header(port)
                    liveCounters
                    if port.isM8UPhysical { hardwareNotes(port) }
                    routesList(port)
                } else {
                    EmptyStateView(
                        symbol: "questionmark.circle",
                        title: "Port not present",
                        message: "This port is not currently part of the MIDI setup."
                    )
                }
            }
            .padding(14)
        }
        .background(Palette.panelRaised)
        .onAppear { draftLabel = state.label(for: portID) }
        .onChange(of: portID) { _, _ in
            draftLabel = state.label(for: portID)
            isEditingLabel = false
        }
    }

    // MARK: Header

    private func header(_ port: MIDIPort) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LED(direction: port.direction, size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(port.id.shortName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(directionDescription(port.direction))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.color(for: port.direction))
                }
                Spacer()
            }

            HStack(spacing: 6) {
                TextField("Name this port", text: $draftLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commitLabel() }
                Button("Rename") { commitLabel() }
                    .disabled(draftLabel == state.label(for: portID))
            }
            Text("Naming a port is how you turn socket 7 into “Prophet 6”. Stored with the rig.")
                .font(.system(size: 9))
                .faintText()

            Toggle(
                "Show in the patchbay",
                isOn: Binding(
                    get: { !(engine.portConfigs[portID]?.hidden ?? false) },
                    set: { state.setPortHidden(portID, hidden: !$0) }
                )
            )
            .controlSize(.small)
        }
    }

    private func directionDescription(_ direction: PortDirection) -> String {
        switch direction {
        case .input: return "Working as an input"
        case .output: return "Working as an output"
        case .idle: return "No traffic seen yet"
        }
    }

    private func commitLabel() {
        state.renamePort(portID, to: draftLabel)
        isEditingLabel = false
    }

    // MARK: Live counters

    private var liveCounters: some View {
        Panel(title: "Live activity") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    StatBlock("Rate", value: Format.rate(stats?.messagesPerSecond ?? 0))
                    StatBlock("Peak", value: Format.rate(stats?.peakMessagesPerSecond ?? 0))
                    StatBlock("Messages", value: Format.count(stats?.messageCount ?? 0))
                    StatBlock("Data", value: Format.bytes(stats?.byteCount ?? 0))
                }

                ActivityMeter(
                    level: engine.portLevels[portID] ?? 0,
                    peak: engine.portPeaks[portID] ?? 0,
                    direction: port?.direction ?? .idle,
                    height: 8
                )

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Channels seen")
                        .font(.system(size: 10, weight: .semibold))
                    ChannelStrip(mask: stats?.activeChannelMask ?? 0, dimmedWhenClear: false)
                    Text(channelDescription)
                        .font(.system(size: 9))
                        .mutedText()
                }
            }
        }
    }

    private var channelDescription: String {
        let mask = stats?.activeChannelMask ?? 0
        let numbers = (0..<16).filter { mask & (1 << UInt16($0)) != 0 }.map { $0 + 1 }
        if numbers.isEmpty { return "Nothing transmitted on this port yet" }
        return "Channels " + numbers.map(String.init).joined(separator: ", ")
    }

    // MARK: Hardware notes

    private func hardwareNotes(_ port: MIDIPort) -> some View {
        Panel(title: "Hardware") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Socket", value: port.id.shortName)
                if let source = port.source {
                    LabeledContent("CoreMIDI source", value: "\(source.name) · id \(source.uniqueID)")
                    LabeledContent("Status", value: source.offline ? "offline" : "online")
                }
                if let destination = port.destination {
                    LabeledContent("CoreMIDI destination", value: "\(destination.name) · id \(destination.uniqueID)")
                }
                Divider()
                Text("The M8U eX decides each socket's direction in hardware, from whether data is "
                     + "flowing in or out. macOS can only observe the result — which is what the LED "
                     + "colour here reflects.")
                    .font(.system(size: 9))
                    .mutedText()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
        }
    }

    // MARK: Routes

    private func routesList(_ port: MIDIPort) -> some View {
        let outgoing = engine.routes.filter { $0.sourcePortID == portID }
        let incoming = engine.routes.filter { $0.destinationPortID == portID }

        return Panel(title: "Routes") {
            VStack(alignment: .leading, spacing: 8) {
                if outgoing.isEmpty && incoming.isEmpty {
                    Text("No routes touch this port. Open the Patchbay and click where it should go.")
                        .font(.system(size: 10))
                        .mutedText()
                }

                if !outgoing.isEmpty {
                    Text("SENDING TO")
                        .font(.system(size: 9, weight: .semibold))
                        .mutedText()
                    ForEach(outgoing) { route in
                        RouteRow(
                            engine: engine,
                            route: route,
                            counterpart: state.label(for: route.destinationPortID),
                            isOutgoing: true
                        )
                    }
                }

                if !incoming.isEmpty {
                    Text("RECEIVING FROM")
                        .font(.system(size: 9, weight: .semibold))
                        .mutedText()
                    ForEach(incoming) { route in
                        RouteRow(
                            engine: engine,
                            route: route,
                            counterpart: state.label(for: route.sourcePortID),
                            isOutgoing: false
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Route row

struct RouteRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var engine: MIDIEngine
    let route: Route
    let counterpart: String
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isOutgoing ? "arrow.right" : "arrow.left")
                .font(.system(size: 9))
                .foregroundStyle(route.isEnabled ? Palette.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(counterpart)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(route.channels.label)
                    if let summary = route.transform.summary {
                        Text("·")
                        Text(summary)
                    }
                }
                .font(.system(size: 9))
                .mutedText()
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { route.isEnabled },
                set: { newValue in
                    var updated = route
                    updated.isEnabled = newValue
                    engine.updateRoute(updated)
                    state.scheduleAutosave()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Button {
                state.selectedRouteID = route.id
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Edit filters and transforms")

            Button {
                engine.removeRoutes(from: route.sourcePortID, to: route.destinationPortID)
                state.scheduleAutosave()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this route")
        }
        .padding(.vertical, 3)
    }
}
