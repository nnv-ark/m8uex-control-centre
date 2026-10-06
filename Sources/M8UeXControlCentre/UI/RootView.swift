import SwiftUI

// MARK: - Root view

/// The main window: sections on the left, the active view in the middle, and a
/// context-sensitive inspector on the right.
public struct RootView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var engine: MIDIEngine
    @State private var inspectorVisible = true

    public init(engine: MIDIEngine) {
        self.engine = engine
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        // No `preferredColorScheme`: the app follows the system appearance, and
        // every colour in `Palette` resolves per appearance. Pinning the scheme is
        // exactly what made a Light-mode Mac render near-black text on dark panels
        // — the surfaces were fixed while the semantic styles still followed the
        // system.
        .onChange(of: engine.ports.count) { _, _ in
            // Devices appearing or disappearing changes what the engine knows about
            // external endpoint names, so persist them. Quietly: plugging something
            // in is not an edit the user should be warned about losing.
            state.persistWorkingStateQuietly()
        }
        .sheet(isPresented: $state.isProfileManagerPresented) {
            ProfileManagerView(engine: engine)
                .environmentObject(state)
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(message: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.toast)
        .frame(minWidth: 1180, minHeight: 720)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $state.section) {
            Section {
                ForEach(AppState.Section.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            } header: {
                Text("Interface").foregroundStyle(.primary)
            }

            Section {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.hardwareOnline ? Palette.input : Palette.output)
                        .frame(width: 8, height: 8)
                    Text(engine.hardwareOnline ? "Online" : "Not detected")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                if engine.connectedUnitCount > 1 {
                    Text("\(engine.connectedUnitCount) units")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text("\(engine.m8uPorts.count) MIDI sockets")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hardware").foregroundStyle(.primary)
            }

            Section {
                if let profile = state.store.activeProfile {
                    Text(profile.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                } else {
                    Text("No rig loaded")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if state.hasUnsavedChanges {
                    HStack(spacing: 5) {
                        Image(systemName: "circle.fill").font(.system(size: 7))
                        Text("Unsaved changes").font(.system(size: 10))
                    }
                    .foregroundStyle(.orange)
                }
                Button {
                    state.isProfileManagerPresented = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10))
                        Text("Manage rigs…")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.link)
            } header: {
                Text("Rig").foregroundStyle(.primary)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        HStack(spacing: 0) {
            Group {
                switch state.section {
                case .dashboard:
                    DashboardView(engine: engine)
                case .patchbay:
                    PatchbayView(engine: engine)
                case .monitor:
                    MonitorView(engine: engine)
                case .diagnostics:
                    DiagnosticsView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                Divider()
                inspector
                    .frame(width: 330)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let routeID = state.selectedRouteID, engine.routes.contains(where: { $0.id == routeID }) {
            RouteInspectorView(engine: engine, routeID: routeID)
        } else if let portID = state.selectedPortID {
            PortInspectorView(engine: engine, portID: portID)
        } else {
            VStack(spacing: 14) {
                EmptyStateView(
                    symbol: "sidebar.right",
                    title: "Nothing selected",
                    message: "Select a port on the Dashboard or a route in the Patchbay to inspect and edit it here."
                )
                Button("Recent events") {
                    state.section = .monitor
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.panelRaised)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                inspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Show or hide the inspector")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if state.hasUnsavedChanges {
                Button {
                    state.saveCurrentAsProfile(
                        named: state.store.activeProfile?.name ?? "Untitled rig"
                    )
                } label: {
                    Label("Save rig", systemImage: "square.and.arrow.down")
                }
                .help("Save the current patch into the loaded rig")
            }

            Button {
                state.isProfileManagerPresented = true
            } label: {
                Label("Rigs", systemImage: "square.stack.3d.up")
            }
            .help("Save, load, import and export rigs")

            Menu {
                Button("Rescan MIDI devices") { engine.refresh() }
                Button("Reset counters") {
                    engine.resetStatistics()
                    engine.clearMonitor()
                }
                Divider()
                Toggle("Log MIDI to the monitor", isOn: Binding(
                    get: { engine.monitorEnabled },
                    set: { engine.monitorEnabled = $0 }
                ))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Palette.scrim)
            )
            .overlay(Capsule().strokeBorder(Palette.stroke))
            .foregroundStyle(.white)
            .shadow(radius: 8, y: 2)
    }
}
