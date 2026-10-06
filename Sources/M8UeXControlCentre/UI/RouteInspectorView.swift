import SwiftUI

// MARK: - Route inspector

/// The detail editor for one connection: channel filtering, message-type
/// filtering and per-route transforms. This is what turns a plain wire into a
/// useful patch — thinning a controller down to one channel before it reaches a
/// synth, transposing a keyboard, or keeping clock off a port that chokes on it.
public struct RouteInspectorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var engine: MIDIEngine
    let routeID: UUID

    public init(engine: MIDIEngine, routeID: UUID) {
        self.engine = engine
        self.routeID = routeID
    }

    private var route: Route? {
        engine.routes.first { $0.id == routeID }
    }

    public var body: some View {
        ScrollView {
            if let route {
                VStack(alignment: .leading, spacing: 14) {
                    header(route)
                    channelSection(route)
                    messageTypeSection(route)
                    transformSection(route)
                    testSection(route)
                }
                .padding(14)
            } else {
                EmptyStateView(
                    symbol: "arrow.triangle.branch",
                    title: "No route selected",
                    message: "Click a connection in the Patchbay, or a cell's ▸ Edit route menu item, to fine-tune what it passes."
                )
            }
        }
        .background(Palette.panelRaised)
    }

    /// Applies a change to the live route and schedules a save.
    private func mutate(_ change: (inout Route) -> Void) {
        guard var current = route else { return }
        change(&current)
        engine.updateRoute(current)
        state.scheduleAutosave()
    }

    // MARK: Header

    private func header(_ route: Route) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(state.label(for: route.sourcePortID))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .mutedText()
                Text(state.label(for: route.destinationPortID))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }

            Toggle("Route enabled", isOn: Binding(
                get: { route.isEnabled },
                set: { newValue in mutate { $0.isEnabled = newValue } }
            ))
            .controlSize(.small)
            .font(.system(size: 11))

            HStack(spacing: 8) {
                Button {
                    state.toggleRoute(from: route.destinationPortID, to: route.sourcePortID)
                } label: {
                    Label("Add reverse route", systemImage: "arrow.uturn.left")
                }
                .controlSize(.small)
                .help("Create a matching route in the opposite direction")

                Button(role: .destructive) {
                    engine.removeRoutes(from: route.sourcePortID, to: route.destinationPortID)
                    state.selectedRouteID = nil
                    state.scheduleAutosave()
                } label: {
                    Label("Disconnect", systemImage: "scissors")
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Channels

    private func channelSection(_ route: Route) -> some View {
        Panel(
            title: "Channels",
            subtitle: "only these channels pass through"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                    ForEach(0..<16, id: \.self) { index in
                        let on = route.channels.contains(channelIndex: index)
                        Button {
                            mutate { current in
                                var mask = current.channels
                                mask.set(channelIndex: index, !on)
                                current.channels = mask
                            }
                        } label: {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .frame(width: 26, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(on ? Palette.accent : Palette.subtleFill)
                                )
                                .foregroundStyle(on ? Palette.panel : Palette.text)
                        }
                        .buttonStyle(.plain)
                        .help("Channel \(index + 1)")
                    }
                }

                HStack(spacing: 8) {
                    Button("All") {
                        mutate { $0.channels = .all }
                    }
                    Button("None") {
                        mutate { $0.channels = .none }
                    }
                    Button("1–8") {
                        mutate { $0.channels = ChannelMask(rawValue: 0x00FF) }
                    }
                    Button("9–16") {
                        mutate { $0.channels = ChannelMask(rawValue: 0xFF00) }
                    }
                    Spacer()
                    Text(route.channels.label)
                        .font(.system(size: 10))
                        .mutedText()
                }
                .controlSize(.small)

                if route.channels.isEmpty {
                    Label("No channels are enabled, so this route passes nothing.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Message types

    private func messageTypeSection(_ route: Route) -> some View {
        Panel(
            title: "Message types",
            subtitle: "turn off what a device should never receive"
        ) {
            let kinds = route.messageKinds
            return VStack(alignment: .leading, spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 4) {
                    kindToggle("Notes", isOn: kinds.note) { value in mutate { $0.messageKinds.note = value } }
                    kindToggle("Pitch bend", isOn: kinds.pitchBend) { value in mutate { $0.messageKinds.pitchBend = value } }
                    kindToggle("Control change", isOn: kinds.controlChange) { value in mutate { $0.messageKinds.controlChange = value } }
                    kindToggle("Program change", isOn: kinds.programChange) { value in mutate { $0.messageKinds.programChange = value } }
                    kindToggle("Channel aftertouch", isOn: kinds.channelAftertouch) { value in mutate { $0.messageKinds.channelAftertouch = value } }
                    kindToggle("Poly aftertouch", isOn: kinds.polyAftertouch) { value in mutate { $0.messageKinds.polyAftertouch = value } }
                    kindToggle("MIDI clock", isOn: kinds.clock) { value in mutate { $0.messageKinds.clock = value } }
                    kindToggle("Transport", isOn: kinds.transport) { value in mutate { $0.messageKinds.transport = value } }
                    kindToggle("Song position", isOn: kinds.songPosition) { value in mutate { $0.messageKinds.songPosition = value } }
                    kindToggle("System exclusive", isOn: kinds.systemExclusive) { value in mutate { $0.messageKinds.systemExclusive = value } }
                }
                HStack {
                    Button("Allow everything") {
                        mutate { $0.messageKinds = .everything }
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private func kindToggle(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
    }

    // MARK: Transforms

    private func transformSection(_ route: Route) -> some View {
        Panel(
            title: "Transform",
            subtitle: "change the data on its way through"
        ) {
            let transform = route.transform
            return VStack(alignment: .leading, spacing: 12) {
                // Transpose
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Transpose")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(transposeLabel(transform.transpose))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(transform.transpose == 0 ? .secondary : Palette.accent)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(transform.transpose) },
                            set: { value in mutate { $0.transform.transpose = Int(value.rounded()) } }
                        ),
                        in: -24...24,
                        step: 1
                    )
                }

                // Velocity scale
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Velocity scale")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(String(format: "%.2f×", transform.velocityScale))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(transform.velocityScale == 1 ? .secondary : Palette.accent)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { transform.velocityScale },
                            set: { value in mutate { $0.transform.velocityScale = value } }
                        ),
                        in: 0...2,
                        step: 0.05
                    )
                }

                // Velocity offset
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Velocity offset")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(transform.velocityOffset == 0 ? "none" : "\(transform.velocityOffset > 0 ? "+" : "")\(transform.velocityOffset)")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(transform.velocityOffset == 0 ? .secondary : Palette.accent)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(transform.velocityOffset) },
                            set: { value in mutate { $0.transform.velocityOffset = Int(value.rounded()) } }
                        ),
                        in: -64...64,
                        step: 1
                    )
                }

                // Force channel
                HStack(spacing: 8) {
                    Text("Force channel")
                        .font(.system(size: 11, weight: .medium))
                    Picker("", selection: Binding(
                        get: { transform.forceChannel ?? 0 },
                        set: { value in mutate { $0.transform.forceChannel = value == 0 ? nil : value } }
                    )) {
                        Text("keep original").tag(0)
                        ForEach(1...16, id: \.self) { channel in
                            Text("Ch \(channel)").tag(channel)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .controlSize(.small)
                    Spacer()
                }

                // Note range
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Note range")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(MIDIMessage.noteName(transform.noteRangeLow)) – \(MIDIMessage.noteName(transform.noteRangeHigh))")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(isFullNoteRange(transform) ? .secondary : Palette.accent)
                    }
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { Double(transform.noteRangeLow) },
                                set: { value in
                                    mutate {
                                        let clamped = UInt8(clamping: Int(value.rounded()))
                                        $0.transform.noteRangeLow = min(clamped, $0.transform.noteRangeHigh)
                                    }
                                }
                            ),
                            in: 0...127,
                            step: 1
                        )
                        Slider(
                            value: Binding(
                                get: { Double(transform.noteRangeHigh) },
                                set: { value in
                                    mutate {
                                        let clamped = UInt8(clamping: Int(value.rounded()))
                                        $0.transform.noteRangeHigh = max(clamped, $0.transform.noteRangeLow)
                                    }
                                }
                            ),
                            in: 0...127,
                            step: 1
                        )
                    }
                }

                HStack {
                    Button("Reset transform") {
                        mutate { $0.transform = .identity }
                    }
                    .controlSize(.small)
                    .disabled(transform.isIdentity)
                    Spacer()
                    if let summary = transform.summary {
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.accent)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func isFullNoteRange(_ transform: RouteTransform) -> Bool {
        transform.noteRangeLow == 0 && transform.noteRangeHigh == 127
    }

    private func transposeLabel(_ semitones: Int) -> String {
        if semitones == 0 { return "none" }
        return "\(semitones > 0 ? "+" : "")\(semitones) semitones"
    }

    // MARK: Test

    private func testSection(_ route: Route) -> some View {
        Panel(
            title: "Send a test message",
            subtitle: "verify the cable and the receiving device"
        ) {
            HStack(spacing: 8) {
                Button("Note on") {
                    engine.sendTestMessage([0x90, 60, 100], to: route.destinationPortID)
                }
                Button("Note off") {
                    engine.sendTestMessage([0x80, 60, 0], to: route.destinationPortID)
                }
                Button("All notes off") {
                    for channel in UInt8(0)..<16 {
                        engine.sendTestMessage([0xB0 | channel, 123, 0], to: route.destinationPortID)
                    }
                }
                Button("Panic") {
                    for channel in UInt8(0)..<16 {
                        engine.sendTestMessage([0xB0 | channel, 120, 0], to: route.destinationPortID)
                        engine.sendTestMessage([0xB0 | channel, 123, 0], to: route.destinationPortID)
                    }
                }
                Spacer()
            }
            .controlSize(.small)

            Text("Sends straight to \(state.label(for: route.destinationPortID)), bypassing this route's filters, so you can prove the destination works before debugging the patch.")
                .font(.system(size: 9))
                .mutedText()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
