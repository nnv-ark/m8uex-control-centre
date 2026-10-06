import Foundation
import SwiftUI
import AppKit
import ServiceManagement

// MARK: - App state

/// Ties the CoreMIDI engine to the profile store and holds all UI selection
/// state. Views observe this and never talk to CoreMIDI directly.
@MainActor
public final class AppState: ObservableObject {

    // MARK: Sections

    public enum Section: String, CaseIterable, Identifiable, Hashable {
        case dashboard
        case patchbay
        case monitor
        case diagnostics

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .patchbay: return "Patchbay"
            case .monitor: return "Monitor"
            case .diagnostics: return "Diagnostics"
            }
        }

        public var symbol: String {
            switch self {
            case .dashboard: return "square.grid.3x3.fill"
            case .patchbay: return "arrow.triangle.branch"
            case .monitor: return "list.bullet.rectangle"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    // MARK: Observable state

    @Published public var section: Section = .dashboard
    @Published public var selectedPortID: MIDIPort.ID?
    @Published public var selectedRouteID: UUID?
    /// When set, the next port the user clicks becomes the other end of a route
    /// from this port. Drives click-to-connect in the patchbay.
    @Published public var pendingConnectSource: MIDIPort.ID?
    /// Free-text filter applied to the monitor.
    @Published public var monitorFilter: String = ""
    /// When true the monitor only shows events whose message matches `monitorFilter`.
    @Published public var monitorPaused: Bool = false
    /// Set by the profile manager sheet.
    @Published public var isProfileManagerPresented: Bool = false
    /// A transient message shown as a toast, e.g. "Rig saved".
    @Published public var toast: String?
    /// Whether the user has edited the working state since the last save.
    @Published public var hasUnsavedChanges: Bool = false

    /// Whether the patchbay and dashboard show endpoints beyond the ESI hardware.
    ///
    /// CoreMIDI publishes every virtual endpoint on the system — the twelve
    /// "SSL V-MIDI" ports from a driver for hardware that is not even connected,
    /// Bluetooth, network sessions, IAC buses. They are legitimate routing targets
    /// and the app can patch to them, but they are noise for someone working with
    /// two interfaces, so they are hidden until asked for.
    ///
    /// Persisted, because it is a preference about how someone works rather than
    /// part of a rig.
    @Published public var showsExternalEndpoints: Bool {
        didSet {
            UserDefaults.standard.set(showsExternalEndpoints, forKey: Self.externalEndpointsKey)
        }
    }

    private static let externalEndpointsKey = "showsExternalEndpoints"

    /// Whether closing the main window leaves the app running so routing continues.
    ///
    /// Defaults to **true**, because the interface has no routing of its own while a
    /// computer is connected — this app *is* the router, so quitting it silently
    /// stops every route. Closing a window is not an instruction to tear the rig
    /// down, and someone who has just lost their routing has no way to tell why.
    /// ⌘Q still quits properly.
    @Published public var routesInBackground: Bool {
        didSet {
            UserDefaults.standard.set(routesInBackground, forKey: Self.backgroundKey)
            onBackgroundPreferenceChanged?(routesInBackground)
        }
    }

    /// Whether the app starts automatically at login, so routing comes back after a
    /// reboot without anyone having to remember to launch it.
    @Published public var launchAtLogin: Bool = false

    private static let backgroundKey = "routesInBackground"

    /// Called when the background preference changes, so the app can show or hide
    /// its menu bar item.
    public var onBackgroundPreferenceChanged: ((Bool) -> Void)?

    public let engine: MIDIEngine
    public let store: RigStore

    private var autosaveWorkItem: DispatchWorkItem?
    private var engineObservers: [Any] = []

    public init(engine: MIDIEngine = MIDIEngine(), store: RigStore = RigStore()) {
        self.engine = engine
        self.store = store
        // Default to hardware only: a fresh install should show the interfaces the
        // app exists for, not every virtual endpoint the system happens to publish.
        self.showsExternalEndpoints = UserDefaults.standard.bool(forKey: Self.externalEndpointsKey)
        // Background routing defaults ON. A missing key reads as false, so the
        // default is established explicitly rather than by accident.
        if UserDefaults.standard.object(forKey: Self.backgroundKey) == nil {
            self.routesInBackground = true
        } else {
            self.routesInBackground = UserDefaults.standard.bool(forKey: Self.backgroundKey)
        }
    }

    // MARK: Lifecycle

    /// Restores the working state then starts CoreMIDI.
    public func start() {
        restoreWorkingState()
        engine.start()
        // Deliberately does not touch `hasUnsavedChanges` here: a rescan that
        // arrives during startup can legitimately flag changes, and clearing the
        // flag blindly would hide them.
    }

    public func shutdown() {
        persistWorkingState()
        engine.disconnectAll()
        engine.stop()
    }

    /// Called when the last window closes and background routing is enabled.
    ///
    /// The engine is deliberately left running: it is the only thing turning DIN
    /// input into routed output. Only the UI goes away.
    public func enterBackgroundMode() {
        // Remember that routing is live so a relaunch can restore the window state
        // rather than starting invisible.
        UserDefaults.standard.set(true, forKey: "wasRoutingInBackground")
    }

    /// Brings the app fully forward again from the menu bar.
    public func exitBackgroundMode() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    private func restoreWorkingState() {
        guard let state = store.loadWorkingState() else {
            // First launch: nothing saved yet, so there is nothing unsaved either.
            engine.portConfigs = [:]
            engine.routes = []
            hasUnsavedChanges = false
            return
        }
        engine.portConfigs = state.portConfigs
        engine.routes = state.routes
        engine.externalPortNames = state.externalPortNames
        store.markActive(state.activeProfileID)
        hasUnsavedChanges = false
    }

    // MARK: Working state persistence

    /// Coalesces rapid edits into one write so dragging a slider does not hammer the disk.
    public func scheduleAutosave() {
        hasUnsavedChanges = true
        autosaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persistWorkingState()
        }
        autosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// Saves the working state without marking the rig as having unsaved edits.
    ///
    /// Needed because the engine learns external endpoint names only once the
    /// CoreMIDI graph has been enumerated. If those names were never written to
    /// disk, a route to a USB device would be re-matched by ID only — which breaks
    /// the moment that device is replugged and gets a new ID. A device appearing is
    /// not a user edit, so it must not flag the rig dirty.
    public func persistWorkingStateQuietly() {
        store.saveWorkingState(
            RigStore.WorkingState(
                activeProfileID: store.activeProfileID,
                portConfigs: engine.portConfigs,
                routes: engine.routes,
                externalPortNames: engine.externalPortNames
            )
        )
    }

    public func persistWorkingState() {
        let state = RigStore.WorkingState(
            activeProfileID: store.activeProfileID,
            portConfigs: engine.portConfigs,
            routes: engine.routes,
            externalPortNames: engine.externalPortNames
        )
        store.saveWorkingState(state)
    }

    // MARK: Routing

    /// Adds or removes a route between two ports, which is what clicking a
    /// matrix cell does.
    public func toggleRoute(from source: MIDIPort.ID, to destination: MIDIPort.ID) {
        guard source != destination else { return }
        if engine.hasActiveRoute(from: source, to: destination) {
            engine.removeRoutes(from: source, to: destination)
        } else {
            engine.addRoute(from: source, to: destination)
        }
        scheduleAutosave()
    }

    /// Click-to-connect: the first click arms a source, the second completes it.
    public func handleConnectClick(on portID: MIDIPort.ID) {
        guard let pending = pendingConnectSource else {
            pendingConnectSource = portID
            return
        }
        if pending == portID {
            pendingConnectSource = nil
            return
        }
        toggleRoute(from: pending, to: portID)
        pendingConnectSource = nil
    }

    public func clearAllRoutes() {
        engine.replaceRoutes([])
        scheduleAutosave()
        show(toast: "All routes cleared")
    }

    /// Silences every destination: All Notes Off plus All Sound Off on all 16
    /// channels, to every port that can output.
    ///
    /// A stuck note is the single most common live-emergency with a MIDI rig, so
    /// this reaches every socket rather than only the routed ones.
    public func panic() {
        var sent = 0
        for port in engine.ports where port.destination != nil {
            for channel in UInt8(0)..<16 {
                engine.sendTestMessage([0xB0 | channel, 123, 0], to: port.id)   // All notes off
                engine.sendTestMessage([0xB0 | channel, 120, 0], to: port.id)   // All sound off
                engine.sendTestMessage([0xB0 | channel, 64, 0], to: port.id)    // Sustain pedal off
            }
            sent += 1
        }
        show(toast: sent > 0 ? "Panic sent to \(sent) ports" : "No output ports available")
    }

    // MARK: Ports

    public func renamePort(_ portID: MIDIPort.ID, to newName: String) {
        var config = engine.portConfigs[portID] ?? PortConfig()
        config.customLabel = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.portConfigs[portID] = config
        scheduleAutosave()
    }

    public func setPortHidden(_ portID: MIDIPort.ID, hidden: Bool) {
        var config = engine.portConfigs[portID] ?? PortConfig()
        config.hidden = hidden
        engine.portConfigs[portID] = config
        scheduleAutosave()
    }

    /// The display label for a port.
    ///
    /// Order matters, and the middle step is the important one: the engine's live
    /// label already carries the interface name ("ESI M4U eX · Port 3"), which is
    /// what keeps two connected units distinguishable. Falling straight through to
    /// `shortName` would render a bare "Port 3" twice over — once for each unit —
    /// and there would be no way to tell which socket a tile or a matrix row
    /// referred to.
    public func label(for portID: MIDIPort.ID) -> String {
        if let custom = engine.portConfigs[portID]?.customLabel, !custom.isEmpty { return custom }
        if let live = engine.ports.first(where: { $0.id == portID })?.label, !live.isEmpty { return live }
        return portID.shortName
    }

    /// The same label with the interface name stripped.
    ///
    /// Only for places that already state the interface separately — the dashboard
    /// groups its tiles under a per-unit heading, so repeating "ESI M4U eX" inside
    /// every tile wastes the space the socket number and live rate need.
    public func compactLabel(for portID: MIDIPort.ID) -> String {
        let full = label(for: portID)
        if let unitName = portID.unitName, full.hasPrefix(unitName) {
            let stripped = full
                .dropFirst(unitName.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·-"))
            if !stripped.isEmpty { return stripped }
        }
        return full
    }

    // MARK: Profiles

    public func saveCurrentAsProfile(named name: String, details: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Untitled rig" : trimmed

        if var existing = store.profiles.first(where: { $0.name == resolved }) {
            existing.details = details
            existing.portConfigs = engine.portConfigs
            existing.routes = engine.routes
            store.save(existing)
        } else {
            let profile = RigProfile(
                name: resolved,
                details: details,
                portConfigs: engine.portConfigs,
                routes: engine.routes
            )
            store.save(profile)
        }
        hasUnsavedChanges = false
        persistWorkingState()
        show(toast: "Saved “\(resolved)”")
    }

    public func load(profile: RigProfile) {
        engine.portConfigs = profile.portConfigs
        engine.routes = profile.routes
        store.markActive(profile.id)
        hasUnsavedChanges = false
        persistWorkingState()
        show(toast: "Loaded “\(profile.name)”")
    }

    public func delete(profile: RigProfile) {
        store.delete(profile)
        persistWorkingState()
    }

    public func export(profile: RigProfile, to url: URL) {
        do {
            try store.export(profile, to: url)
            show(toast: "Exported to \(url.lastPathComponent)")
        } catch {
            show(toast: "Export failed: \(error.localizedDescription)")
        }
    }

    public func importProfile(from url: URL) {
        do {
            let profile = try store.importProfile(from: url)
            show(toast: "Imported “\(profile.name)”")
        } catch {
            show(toast: "Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: Toasts

    public func show(toast message: String) {
        toast = message
        let current = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            // Only clear if no newer toast replaced this one.
            if self?.toast == current { self?.toast = nil }
        }
    }

    // MARK: Derived data

    /// Ports shown in the patchbay and dashboard, honouring the hidden flag and the
    /// external-endpoint preference.
    public var visiblePorts: [MIDIPort] {
        engine.ports
            .filter { !(engine.portConfigs[$0.id]?.hidden ?? false) }
            .filter { showsExternalEndpoints || $0.isM8UPhysical }
    }

    /// External endpoints that the preference is currently hiding, so the UI can
    /// say what is being kept out of the way rather than silently omitting it.
    public var hiddenExternalPortCount: Int {
        guard !showsExternalEndpoints else { return 0 }
        return engine.ports.filter { !$0.isM8UPhysical }.count
    }

    /// M8U sockets in order, for the dashboard's 16-tile grid.
    public var hardwarePorts: [MIDIPort] {
        engine.ports.filter { $0.isM8UPhysical }.sorted { $0.sortKey < $1.sortKey }
    }

    /// Everything that can be routed, hardware first then external endpoints.
    public var routablePorts: [MIDIPort] {
        visiblePorts.filter { $0.source != nil || $0.destination != nil }
    }

    public var selectedPort: MIDIPort? {
        guard let selectedPortID else { return nil }
        return engine.ports.first { $0.id == selectedPortID }
    }
}
