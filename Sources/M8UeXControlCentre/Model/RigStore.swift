import Foundation
import SwiftUI

// MARK: - Rig profile

/// A complete, saveable description of how the interface is set up: what each
/// port is called and how signals are patched between them.
///
/// Ports are identified by `MIDIPort.ID` rather than by CoreMIDI endpoint
/// references, so a rig survives reboots, replugs and USB port changes.
public struct RigProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Free-text description shown in the profile list.
    public var details: String
    public var portConfigs: [MIDIPort.ID: PortConfig]
    public var routes: [Route]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        details: String = "",
        portConfigs: [MIDIPort.ID: PortConfig] = [:],
        routes: [Route] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.portConfigs = portConfigs
        self.routes = routes
        // Timestamps are truncated to whole seconds.
        //
        // Two reasons: a rig is edited by a human, so sub-second accuracy is
        // meaningless, and the JSON form cannot round-trip a `Date`'s full
        // precision. Without this, a profile read back from disk would never
        // compare equal to the one in memory, and the app would report unsaved
        // changes the moment it loaded a rig.
        self.createdAt = createdAt.roundedToSecond()
        self.updatedAt = updatedAt.roundedToSecond()
    }
}

extension Date {
    /// Truncates to whole seconds, the precision rig files are stored at.
    func roundedToSecond() -> Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded())
    }
}

// MARK: - Rig coding

/// The single definition of how a rig is written to disk.
///
/// Every path that reads or writes a `.m8uprofile` goes through here — the
/// profile library, the working state and file import/export — so a rig exported
/// from one install is always readable by another. Dates are stored as epoch
/// seconds because the textual ISO 8601 form is only precise to the second, which
/// would make a profile read back from disk compare unequal to the one in memory
/// and quietly break dirty-state tracking.
public enum RigCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: - Store

/// Persists rig profiles and the live working state.
///
/// Deliberately simple on-disk layout: a JSON file per profile plus a small
/// index, all under `~/Library/Application Support/M8U eX Control Centre/`.
/// Profiles are plain JSON so they can be diffed, hand-edited or committed to
/// a rig repository — which is how a venue or tour would version a patchbay.
public final class RigStore: ObservableObject {

    /// Every saved profile, newest first.
    @Published public private(set) var profiles: [RigProfile] = []
    /// The profile currently loaded into the engine, if any.
    @Published public private(set) var activeProfileID: UUID?
    /// Set when a load or save fails, for display in the UI.
    @Published public private(set) var lastError: String?

    private let fileManager = FileManager.default
    private let encoder = RigCoding.makeEncoder()
    private let decoder = RigCoding.makeDecoder()

    public init() {
        loadAll()
    }

    // MARK: Locations

    /// `~/Library/Application Support/M8U eX Control Centre`
    public var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("M8U eX Control Centre", isDirectory: true)
    }

    private var profilesDirectory: URL {
        supportDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    /// Where the "what was I doing last" state lives.
    private var workingStateURL: URL {
        supportDirectory.appendingPathComponent("WorkingState.json")
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
    }

    // MARK: Load / save

    public func loadAll() {
        do {
            try ensureDirectories()
        } catch {
            lastError = "Could not create the profiles folder: \(error.localizedDescription)"
            return
        }

        let urls = (try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        var loaded: [RigProfile] = []
        for url in urls where url.pathExtension == "m8uprofile" {
            do {
                let data = try Data(contentsOf: url)
                loaded.append(try decoder.decode(RigProfile.self, from: data))
            } catch {
                // One unreadable file must not hide the rest of the user's rigs.
                lastError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        profiles = loaded.sorted { $0.updatedAt > $1.updatedAt }

        if let state = loadWorkingState() {
            activeProfileID = state.activeProfileID
        }
    }

    /// The working state is what the app should restore on launch: the active
    /// profile plus any unsaved edits, so a crash never loses a patch.
    public struct WorkingState: Codable, Sendable {
        public var activeProfileID: UUID?
        public var portConfigs: [MIDIPort.ID: PortConfig]
        public var routes: [Route]
        /// Names of external (non-interface) endpoints, keyed by the identity a
        /// route stores for them.
        ///
        /// A route to, say, a synth over USB is keyed by that device's CoreMIDI
        /// endpoint ID, which changes when it is replugged. Remembering the name
        /// lets such a route be re-matched to the same device afterwards instead
        /// of silently pointing at nothing.
        public var externalPortNames: [MIDIPort.ID: String]

        public init(
            activeProfileID: UUID?,
            portConfigs: [MIDIPort.ID: PortConfig],
            routes: [Route],
            externalPortNames: [MIDIPort.ID: String] = [:]
        ) {
            self.activeProfileID = activeProfileID
            self.portConfigs = portConfigs
            self.routes = routes
            self.externalPortNames = externalPortNames
        }
    }

    public func loadWorkingState() -> WorkingState? {
        guard let data = try? Data(contentsOf: workingStateURL) else { return nil }
        return try? decoder.decode(WorkingState.self, from: data)
    }

    public func saveWorkingState(_ state: WorkingState) {
        do {
            try ensureDirectories()
            let data = try encoder.encode(state)
            try data.write(to: workingStateURL, options: .atomic)
        } catch {
            lastError = "Could not save the working state: \(error.localizedDescription)"
        }
    }

    // MARK: Profile operations

    @discardableResult
    public func save(_ profile: RigProfile) -> RigProfile {
        var updated = profile
        updated.updatedAt = Date()
        do {
            try ensureDirectories()
            let data = try encoder.encode(updated)
            let url = profilesDirectory.appendingPathComponent("\(updated.id.uuidString).m8uprofile")
            try data.write(to: url, options: .atomic)
            if let index = profiles.firstIndex(where: { $0.id == updated.id }) {
                profiles[index] = updated
            } else {
                profiles.insert(updated, at: 0)
            }
            profiles.sort { $0.updatedAt > $1.updatedAt }
            activeProfileID = updated.id
            lastError = nil
        } catch {
            lastError = "Could not save “\(updated.name)”: \(error.localizedDescription)"
        }
        return updated
    }

    public func delete(_ profile: RigProfile) {
        let url = profilesDirectory.appendingPathComponent("\(profile.id.uuidString).m8uprofile")
        try? fileManager.removeItem(at: url)
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
    }

    /// Writes a profile somewhere the user chose, for sharing between machines.
    public func export(_ profile: RigProfile, to url: URL) throws {
        let data = try encoder.encode(profile)
        try data.write(to: url, options: .atomic)
    }

    /// Reads a profile from an arbitrary location and adds it to the library.
    @discardableResult
    public func importProfile(from url: URL) throws -> RigProfile {
        let data = try Data(contentsOf: url)
        var profile = try decoder.decode(RigProfile.self, from: data)
        // Give it a fresh identity so importing twice cannot overwrite the original.
        profile.id = UUID()
        profile.updatedAt = Date()
        return save(profile)
    }

    public func markActive(_ id: UUID?) {
        activeProfileID = id
    }

    public var activeProfile: RigProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }
}
