import SwiftUI

// MARK: - Patchbay

/// The routing matrix: sources down the side, destinations across the top.
/// Clicking a cell connects or disconnects that pair, which is the whole point
/// of the app — repatching without touching a cable.
public struct PatchbayView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var engine: MIDIEngine
    @State private var showingClearConfirmation = false

    public init(engine: MIDIEngine) {
        self.engine = engine
    }

    /// Destinations shown across the top: hardware sockets first, then anything else.
    private var destinations: [MIDIPort] {
        let pool = state.visiblePorts
        return pool
            .filter { $0.destination != nil }
            .filter { !(engine.portConfigs[$0.id]?.hidden ?? false) }
            .sorted { $0.sortKey < $1.sortKey }
    }

    /// Sources shown down the side.
    private var sources: [MIDIPort] {
        let pool = state.visiblePorts
        return pool
            .filter { $0.source != nil }
            .filter { !(engine.portConfigs[$0.id]?.hidden ?? false) }
            .sorted { $0.sortKey < $1.sortKey }
    }

    private let cellWidth: CGFloat = 30
    private let cellHeight: CGFloat = 26
    private let labelWidth: CGFloat = 170

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if sources.isEmpty || destinations.isEmpty {
                EmptyStateView(
                    symbol: "arrow.triangle.branch",
                    title: "Nothing to patch yet",
                    message: engine.hardwareOnline
                        ? "No routable MIDI endpoints were found. Try Rescan on the Dashboard."
                        : "Connect the M8U eX and its 16 sockets will appear here automatically, ready to patch."
                )
            } else {
                matrix
            }
        }
        .background(Palette.windowBackground)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Routing matrix")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(sources.count) sources × \(destinations.count) destinations · "
                     + "\(engine.routes.filter(\.isEnabled).count) active connections")
                    .font(.system(size: 10))
                    .mutedText()
            }

            Spacer()

            if let pending = state.pendingConnectSource {
                HStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    Text("Connect from \(state.label(for: pending)) — click a destination")
                    Button("Cancel") { state.pendingConnectSource = nil }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Palette.accent.opacity(0.18)))
            }

            Toggle("Show external endpoints", isOn: $state.showsExternalEndpoints)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Show IAC buses, network sessions and other MIDI devices as routable sources and destinations")

            Button {
                showingClearConfirmation = true
            } label: {
                Label("Clear all", systemImage: "trash")
            }
            .disabled(engine.routes.isEmpty)
        }
        .padding(12)
        .confirmationDialog(
            "Remove every route?",
            isPresented: $showingClearConfirmation
        ) {
            Button("Clear all routes", role: .destructive) { state.clearAllRoutes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects all \(engine.routes.count) routes between ports. The interface itself keeps working.")
        }
    }

    // MARK: Matrix

    private var matrix: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(sources) { source in
                    sourceRow(source)
                }
            }
            .padding(12)
        }
        .background(Palette.windowBackground)
    }

    private var headerRow: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: labelWidth, height: 1)
            ForEach(destinations) { destination in
                VStack(spacing: 2) {
                    LED(direction: destination.direction, size: 6)
                    Text(shortLabel(destination))
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: cellWidth, height: 22)
                        .rotationEffect(.degrees(-52))
                        .frame(width: cellWidth, height: 40)
                }
                .frame(width: cellWidth)
                .help("Output: \(state.label(for: destination.id))")
            }
        }
        .frame(height: 46)
    }

    private func sourceRow(_ source: MIDIPort) -> some View {
        HStack(spacing: 2) {
            sourceLabel(source)
            ForEach(destinations) { destination in
                MatrixCell(
                    isConnected: engine.hasActiveRoute(from: source.id, to: destination.id),
                    isPending: state.pendingConnectSource == source.id,
                    isSelf: source.id == destination.id,
                    direction: source.direction,
                    hasComplexRoute: engine.route(from: source.id, to: destination.id).map { route in
                        !route.channels.channelNumbers.isEmpty && route.channels.channelNumbers.count < 16
                            || route.transform.summary != nil
                    } ?? false
                )
                .frame(width: cellWidth, height: cellHeight)
                .onTapGesture {
                    if source.id == destination.id { return }
                    state.toggleRoute(from: source.id, to: destination.id)
                }
                .contextMenu {
                    cellMenu(source: source, destination: destination)
                }
                .help(cellTooltip(source: source, destination: destination))
            }
        }
    }

    private func sourceLabel(_ port: MIDIPort) -> some View {
        Button {
            state.selectedPortID = port.id
        } label: {
            HStack(spacing: 6) {
                LED(direction: port.direction, size: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.label(for: port.id))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(port.isM8UPhysical ? port.id.shortName : "endpoint")
                        .font(.system(size: 8))
                        .faintText()
                }
                Spacer(minLength: 0)
                Text(Format.rate(engine.portStats[port.id]?.messagesPerSecond ?? 0))
                    .font(.system(size: 9, design: .rounded))
                    .monospacedDigit()
                    .mutedText()
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: labelWidth, alignment: .leading)
    }

    @ViewBuilder
    private func cellMenu(source: MIDIPort, destination: MIDIPort) -> some View {
        let connected = engine.hasActiveRoute(from: source.id, to: destination.id)
        if source.id != destination.id {
            Button(connected ? "Disconnect" : "Connect") {
                state.toggleRoute(from: source.id, to: destination.id)
            }
            if connected, let route = engine.route(from: source.id, to: destination.id) {
                Button("Disable route") {
                    var updated = route
                    updated.isEnabled = false
                    engine.updateRoute(updated)
                    state.scheduleAutosave()
                }
                Button("Edit route…") {
                    state.selectedRouteID = route.id
                }
            }
            Divider()
            Button("Connect from \(state.label(for: source.id))…") {
                state.pendingConnectSource = source.id
            }
            Button("Inspect \(state.label(for: destination.id))") {
                state.selectedPortID = destination.id
            }
        } else {
            Text("A port cannot route to itself")
        }
    }

    private func cellTooltip(source: MIDIPort, destination: MIDIPort) -> String {
        let connected = engine.hasActiveRoute(from: source.id, to: destination.id)
        var lines = [
            "\(state.label(for: source.id))  →  \(state.label(for: destination.id))",
            connected ? "Connected" : "Not connected"
        ]
        if connected, let route = engine.route(from: source.id, to: destination.id) {
            lines.append("Channels: \(route.channels.label)")
            if let summary = route.transform.summary { lines.append("Transform: \(summary)") }
        }
        lines.append("Click to \(connected ? "disconnect" : "connect")")
        return lines.joined(separator: "\n")
    }

    private func shortLabel(_ port: MIDIPort) -> String {
        let label = state.label(for: port.id)
        if let index = port.m8uIndex { return "\(index)" }
        return String(label.prefix(14))
    }
}

// MARK: - Matrix cell

/// One connection cell. Filled when a route exists; a small dot marks routes
/// that carry filters or transforms so they are not mistaken for a plain wire.
struct MatrixCell: View {
    let isConnected: Bool
    let isPending: Bool
    let isSelf: Bool
    let direction: PortDirection
    let hasComplexRoute: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(background)
            if isConnected {
                if hasComplexRoute {
                    // A dot marks a route that carries filters or transforms, so
                    // it is not mistaken for a plain wire.
                    Circle()
                        .fill(Palette.color(for: direction))
                        .frame(width: 9, height: 9)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.color(for: direction))
                        .padding(3)
                }
            }
            if isSelf {
                Rectangle()
                    .fill(Palette.stroke.opacity(0.55))
                    .frame(width: 9, height: 1)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    isPending ? Palette.accent : Palette.stroke.opacity(0.9),
                    lineWidth: isPending ? 1.5 : 0.5
                )
        )
    }

    private var background: Color {
        if isSelf { return Palette.sunkenFill.opacity(0.6) }
        // A connected cell gets a clearly lighter well so the patch reads at a
        // glance from across a desk; empty cells stay quiet.
        return isConnected ? Palette.strongFill : Palette.subtleFill
    }
}
