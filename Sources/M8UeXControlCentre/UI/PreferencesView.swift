import SwiftUI

// MARK: - Preferences

/// App behaviour settings.
///
/// Both switches exist for one reason: this app is the MIDI router, so if it is
/// not running, the rig is not routed. These two preferences are what stop that
/// from being a surprise — one keeps routing alive when the window closes, the
/// other brings routing back after a reboot.
public struct PreferencesView: View {
    @EnvironmentObject private var state: AppState

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginStatus = LaunchAtLogin.statusDescription
    /// Set when macOS refuses a login-item change, so the toggle can be corrected
    /// to show reality instead of the value the user just clicked.
    @State private var loginError: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                Text("Keeping your routing alive")
                    .font(.system(size: 13, weight: .semibold))
                Text("These devices have no routing of their own while a computer is "
                     + "connected — this app performs it. If the app stops, every route "
                     + "stops with it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: Background routing
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Keep routing when the window is closed", isOn: Binding(
                    get: { state.routesInBackground },
                    set: { state.routesInBackground = $0 }
                ))
                .font(.system(size: 12, weight: .medium))

                Text(state.routesInBackground
                     ? "Closing the window leaves the app running and shows a menu bar "
                       + "item, so MIDI keeps flowing. Press ⌘Q to quit completely."
                     : "Closing the window quits the app, which stops all routing.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: Launch at login
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Start automatically when I log in", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                .font(.system(size: 12, weight: .medium))

                Text(loginError ?? loginStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(loginError == nil ? .secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: Endpoints
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show external MIDI endpoints", isOn: Binding(
                    get: { state.showsExternalEndpoints },
                    set: { state.showsExternalEndpoints = $0 }
                ))
                .font(.system(size: 12, weight: .medium))

                Text("Reveals virtual endpoints — IAC buses, network sessions and other "
                     + "devices — as routable sources and destinations in the Patchbay.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Text("M8U eX Control Centre")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(22)
        .frame(width: 460, height: 380)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            loginStatus = LaunchAtLogin.statusDescription
        }
    }

    /// Applies a login-item change and re-reads the real state afterwards, because
    /// macOS can decline or defer the request.
    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        let result = LaunchAtLogin.setEnabled(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
        loginStatus = LaunchAtLogin.statusDescription

        if enabled && !result {
            loginError = "macOS did not accept the login item. Check System Settings › "
                + "General › Login Items."
        } else if !enabled && result {
            loginError = "macOS did not remove the login item. Check System Settings › "
                + "General › Login Items."
        }
    }
}
