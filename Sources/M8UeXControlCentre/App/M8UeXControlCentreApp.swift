import SwiftUI
import AppKit

// MARK: - App entry point

/// The application.
///
/// Three command-line modes are handled before any UI is built, so the app is
/// fully usable and verifiable from a terminal as well as from Finder:
///
///   * `--selftest`   run the headless engine self test and exit with a status
///                    code. Needs no hardware: it drives the real
///                    receive → filter → transform → send path using a virtual
///                    CoreMIDI loopback.
///   * `--probe`      print the CoreMIDI topology and exit. This is the tool to
///                    run with the M8U eX plugged in, to see exactly what macOS
///                    published for it.
///   * `--dump-ports` like `--probe`, plus the port table this app builds from
///                    it, including which sockets it recognised as M8U eX ports.
@main
struct M8UeXControlCentreApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Mirrors `state.routesInBackground` so SwiftUI can drive the Settings toggle
    /// while AppState stays free of SwiftUI property-wrapper concerns.
    @AppStorage("routesInBackground") private var routesInBackgroundPref: Bool = true

    init() {
        // Before anything else: if this is a command-line invocation, do that
        // work and exit. Nothing is created above this line that CoreMIDI needs.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        if CommandLine.arguments.contains("--probe") {
            exit(TopologyProbe.run(verbose: false))
        }
        if CommandLine.arguments.contains("--dump-ports") {
            exit(TopologyProbe.run(verbose: true))
        }
        if CommandLine.arguments.contains("--watch") {
            exit(ConnectionWatch.run())
        }
        if CommandLine.arguments.contains("--interrogate") {
            exit(DeviceInterrogation.run())
        }
        // --verify-route "<device>" <socket>: prove a real USB MIDI device reaches
        // a real DIN socket through the routing engine.
        if let index = CommandLine.arguments.firstIndex(of: "--verify-out") {
            let rest = CommandLine.arguments.dropFirst(index + 1)
            guard let device = rest.first,
                  let socket = rest.dropFirst().first.flatMap(Int.init) else {
                FileHandle.standardError.write(Data(
                    "usage: --verify-out \"<destination device>\" <socket 1-16>\n".utf8))
                exit(2)
            }
            exit(ReverseRouteCheck.run(destinationName: device, socket: socket))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-route") {
            let rest = CommandLine.arguments.dropFirst(index + 1)
            guard let device = rest.first,
                  let socket = rest.dropFirst().first.flatMap(Int.init) else {
                FileHandle.standardError.write(Data(
                    "usage: --verify-route \"<source device>\" <socket 1-16>\n".utf8))
                exit(2)
            }
            exit(LiveRouteCheck.run(sourceName: device, socket: socket))
        }
    }

    var body: some Scene {
        Window("M8U eX Control Centre", id: "main") {
            RootView(engine: state.engine)
                .environmentObject(state)
                .onAppear {
                    // The AppDelegate owns quit handling and needs the state to
                    // persist the working rig and tear CoreMIDI down cleanly.
                    appDelegate.state = state
                    state.onBackgroundPreferenceChanged = { _ in
                        appDelegate.rebuildStatusItem()
                    }
                    state.start()
                    appDelegate.rebuildStatusItem()
                }
        }
        .defaultSize(width: 1360, height: 840)

        Settings {
            PreferencesView()
                .environmentObject(state)
        }

        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Rig") {
                Button("Save Rig…") {
                    state.isProfileManagerPresented = true
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Manage Rigs…") {
                    state.isProfileManagerPresented = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandMenu("MIDI") {
                Button("Rescan MIDI Devices") {
                    state.engine.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(state.engine.monitorEnabled ? "Pause Monitor Logging" : "Resume Monitor Logging") {
                    state.engine.monitorEnabled.toggle()
                }

                Button("Clear Monitor") {
                    state.engine.clearMonitor()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Reset Counters") {
                    state.engine.resetStatistics()
                }

                Divider()

                Button("Panic — All Notes Off") {
                    state.panic()
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

// MARK: - App delegate

/// Handles the bits SwiftUI does not: terminating cleanly so CoreMIDI
/// connections and virtual endpoints are torn down rather than left dangling,
/// and offering to save unsaved patch changes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Injected by the App struct on first appearance.
    var state: AppState?

    /// The menu bar item, shown while routing continues with no window open.
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildStatusItem()
    }

    /// Closing the window must not stop routing.
    ///
    /// The interface has no routing of its own while a computer is connected, so
    /// this app *is* the router: quit it and every route stops dead. Closing a
    /// window is not an instruction to tear the rig down, so the app stays alive
    /// and shows a menu bar item instead. ⌘Q still quits for real.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let state, state.routesInBackground else { return true }
        state.enterBackgroundMode()
        rebuildStatusItem()
        return false
    }

    /// Clicking the dock icon while running in the background brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            state?.exitBackgroundMode()
        }
        return true
    }

    // MARK: Menu bar

    /// Shows or hides the menu bar item to match the current preference.
    func rebuildStatusItem() {
        let wantsItem = state?.routesInBackground ?? true
        if wantsItem, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(
                systemSymbolName: "pianokeys",
                accessibilityDescription: "M8U eX Control Centre"
            )
            item.button?.toolTip = "M8U eX Control Centre — routing MIDI"

            let menu = NSMenu()
            menu.addItem(withTitle: "Open Control Centre", action: #selector(openWindow), keyEquivalent: "")
            menu.addItem(.separator())
            let status = NSMenuItem(title: "Routing MIDI", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for entry in menu.items where entry.action != nil {
                entry.target = self
            }
            // Quit should go to the application, not this delegate.
            menu.items.last?.target = NSApp
            item.menu = menu
            statusItem = item
        } else if !wantsItem, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func openWindow() {
        state?.exitBackgroundMode()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }

        if state.hasUnsavedChanges, state.store.activeProfile != nil {
            let alert = NSAlert()
            alert.messageText = "Save changes to this rig?"
            alert.informativeText = "Your patch and port names have changed since the rig was last saved."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                state.saveCurrentAsProfile(
                    named: state.store.activeProfile?.name ?? "Untitled rig"
                )
            case .alertThirdButtonReturn:
                return .terminateCancel
            default:
                break
            }
        }

        state.shutdown()
        return .terminateNow
    }
}
