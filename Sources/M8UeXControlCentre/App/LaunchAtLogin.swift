import Foundation
import ServiceManagement
import os

// MARK: - Launch at login

/// Registers the app as a login item.
///
/// Uses `SMAppService`, macOS 13's replacement for the deprecated
/// `LSSharedFileList` and `SMLoginItemSetEnabled` APIs. It requires no helper
/// bundle: the main app registers itself, which is the supported shape for a
/// regular application.
///
/// The whole point is that routing outlives a reboot. The interface has no
/// routing of its own, so if the app does not come back after a restart, the rig
/// silently stops working and nothing tells the user why.
enum LaunchAtLogin {

    private static let log = Logger(subsystem: "is.nnv.m8uex.controlcentre", category: "login")

    /// Whether macOS currently has this app registered as a login item.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the login item.
    ///
    /// Returns the state macOS actually ended up in, which is what the UI should
    /// display — registering can fail (unsigned builds, user denying it in System
    /// Settings), and showing a toggle that disagrees with reality is worse than
    /// showing the failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // Registering twice throws, so only act when a change is needed.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    log.info("registered as a login item")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    log.info("unregistered as a login item")
                }
            }
        } catch {
            log.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return isEnabled
    }

    /// A description of the current status, for display next to the toggle.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Starts automatically when you log in."
        case .notRegistered:
            return "Will not start automatically."
        case .requiresApproval:
            return "Waiting for approval in System Settings › General › Login Items."
        case .notFound:
            return "macOS could not find the app to register it."
        @unknown default:
            return "Status unavailable."
        }
    }
}
