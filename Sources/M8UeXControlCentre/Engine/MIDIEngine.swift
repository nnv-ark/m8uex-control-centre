import Foundation
import CoreMIDI
import os

// MARK: - Timing

public enum MIDITime {
    /// CoreMIDI packet timestamps are in the mach absolute time domain, the
    /// same domain `mach_absolute_time()` returns. Everything in this app that
    /// measures jitter or inter-message gaps converts through here so units
    /// never get mixed up.
    public static func hostTime() -> UInt64 { mach_absolute_time() }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Converts a mach absolute time value to seconds.
    public static func seconds(_ hostTime: UInt64) -> Double {
        let tb = timebase
        return Double(hostTime) * Double(tb.numer) / Double(tb.denom) / 1_000_000_000.0
    }

    /// Converts a duration in seconds to mach absolute time units.
    public static func hostTicks(seconds: Double) -> UInt64 {
        let tb = timebase
        guard tb.denom != 0, tb.numer != 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer))
    }

    /// A monotonic wall-clock-ish instant derived from host time, for log display.
    public static func instant(_ hostTime: UInt64) -> Double { seconds(hostTime) }
}

// MARK: - Statistics

/// Rolling traffic statistics for one port.
public struct PortStats: Sendable {
    public var messageCount: UInt64 = 0
    public var byteCount: UInt64 = 0
    public var noteOnCount: UInt64 = 0
    public var noteOffCount: UInt64 = 0
    public var controlChangeCount: UInt64 = 0
    public var programChangeCount: UInt64 = 0
    public var pitchBendCount: UInt64 = 0
    public var aftertouchCount: UInt64 = 0
    public var clockCount: UInt64 = 0
    public var sysExCount: UInt64 = 0
    public var sysExByteCount: UInt64 = 0
    /// Messages per second, smoothed.
    public var messagesPerSecond: Double = 0
    /// Highest instantaneous rate seen since the last reset.
    public var peakMessagesPerSecond: Double = 0
    /// Reported by the parser when bytes arrive that the MIDI spec disallows.
    public var anomalyCount: UInt64 = 0
    /// Messages discarded because a destination could not keep up.
    public var overflowDroppedCount: UInt64 = 0
    /// Channels observed carrying data, as a 16-bit mask.
    public var activeChannelMask: UInt16 = 0
    /// Most recent note velocity seen, for a note-off/on indicator.
    public var lastVelocity: UInt8 = 0
    /// Set of controller numbers seen, capped for display purposes.
    public var seenControllers: Set<UInt8> = []
    /// Lowest and highest note numbers observed.
    public var lowestNote: UInt8 = 127
    public var highestNote: UInt8 = 0
    public var lastMessageAt: UInt64 = 0

    public mutating func record(_ message: MIDIMessage) {
        messageCount &+= 1
        byteCount &+= UInt64(message.bytes.count)
        lastMessageAt = message.timestamp

        if message.isChannelMessage {
            activeChannelMask |= (1 << UInt16(message.channel))
            switch message.statusNibble {
            case 0x80:
                noteOffCount &+= 1
            case 0x90:
                if message.data2 == 0 {
                    noteOffCount &+= 1
                } else {
                    noteOnCount &+= 1
                    lastVelocity = message.data2
                }
                lowestNote = min(lowestNote, message.data1)
                highestNote = max(highestNote, message.data1)
            case 0xA0:
                aftertouchCount &+= 1
            case 0xB0:
                controlChangeCount &+= 1
                if seenControllers.count < 64 { seenControllers.insert(message.data1) }
            case 0xC0:
                programChangeCount &+= 1
            case 0xD0:
                aftertouchCount &+= 1
            case 0xE0:
                pitchBendCount &+= 1
            default:
                break
            }
        } else if message.isSystemExclusive {
            sysExCount &+= 1
            sysExByteCount &+= UInt64(message.bytes.count)
        } else if message.status == 0xF8 {
            clockCount &+= 1
        }
    }
}

/// A fixed-window rate estimator that also tracks the peak, used to drive the
/// activity bars on the dashboard.
struct RateMeter {
    private var bucketCounts: [UInt64]
    private var bucketStart: UInt64 = 0
    private var currentBucket: Int = 0
    private let bucketTicks: UInt64
    private let bucketCount: Int

    /// - Parameters:
    ///   - window: total averaging window in seconds.
    ///   - buckets: number of sub-buckets; more buckets = smoother decay.
    init(window: Double = 2.0, buckets: Int = 20) {
        self.bucketCount = buckets
        self.bucketCounts = Array(repeating: 0, count: buckets)
        self.bucketTicks = MIDITime.hostTicks(seconds: window / Double(buckets))
    }

    mutating func add(_ count: UInt64 = 1, at hostTime: UInt64) {
        advance(to: hostTime)
        bucketCounts[currentBucket] &+= count
    }

    private mutating func advance(to hostTime: UInt64) {
        guard bucketTicks > 0 else { return }
        if bucketStart == 0 {
            bucketStart = hostTime
            return
        }
        let elapsed = hostTime &- bucketStart
        let steps = Int(elapsed / bucketTicks)
        guard steps > 0 else { return }
        bucketStart = bucketStart &+ UInt64(steps) * bucketTicks
        for step in 0..<min(steps, bucketCount) {
            currentBucket = (currentBucket + 1) % bucketCount
            bucketCounts[currentBucket] = 0
            _ = step
        }
    }

    /// Average messages per second across the whole window.
    mutating func rate(at hostTime: UInt64) -> Double {
        advance(to: hostTime)
        let total = bucketCounts.reduce(0, +)
        let window = Double(bucketCount) * MIDITime.seconds(bucketTicks)
        guard window > 0 else { return 0 }
        return Double(total) / window
    }

    /// 0...1 fill level relative to a supplied full-scale rate, for the UI meter.
    mutating func normalized(at hostTime: UInt64, fullScale: Double) -> Double {
        guard fullScale > 0 else { return 0 }
        return min(1.0, rate(at: hostTime) / fullScale)
    }

    mutating func reset() {
        for index in bucketCounts.indices { bucketCounts[index] = 0 }
        bucketStart = 0
        currentBucket = 0
    }
}

// MARK: - Monitor log

/// One captured event, shown in the monitor and available to the inspector.
public struct MonitoredEvent: Identifiable, Sendable {
    public let id: UInt64
    public let timestamp: UInt64
    public let portID: MIDIPort.ID
    public let portLabel: String
    public let direction: PortDirection
    public let message: MIDIMessage
    /// Route that produced this event, when the event is an output.
    public let routeID: UUID?

    public var seconds: Double { MIDITime.seconds(timestamp) }
}

/// One port's runtime state: its CoreMIDI wiring, its parser and its counters.
///
/// This is deliberately a reference type because the audio/MIDI read path must
/// mutate it without copying, and it is only ever touched from the engine's
/// serial queue.
final class PortRuntime {
    var port: MIDIPort
    var stats = PortStats()
    var meter = RateMeter()
    var parser = MIDIByteStreamParser()
    /// Smoothed activity level 0...1 for the dashboard meter.
    var level: Double = 0
    /// Peak level held briefly so brief notes are visible.
    var peakLevel: Double = 0

    init(port: MIDIPort) {
        self.port = port
    }

    var portID: MIDIPort.ID { port.id }
}

// MARK: - Engine

/// Owns the CoreMIDI client, all connections, the routing graph and all live
/// traffic statistics.
///
/// Threading contract:
///   * CoreMIDI read blocks fire on a high-priority CoreMIDI thread and do the
///     absolute minimum: hand bytes to the engine and return.
///   * All parsing, routing and statistics happen on `workQueue`, a serial queue.
///   * `@Published` state is only mutated on the main queue.
public final class MIDIEngine: ObservableObject {

    // MARK: Published UI state

    /// Every logical port, M8U sockets first, with live direction and levels.
    @Published public private(set) var ports: [MIDIPort] = []
    /// Per-port traffic counters keyed by port id.
    @Published public private(set) var portStats: [MIDIPort.ID: PortStats] = [:]
    /// Smoothed activity levels 0...1 keyed by port id, for the LED meters.
    @Published public private(set) var portLevels: [MIDIPort.ID: Double] = [:]
    /// Peak-hold levels 0...1 keyed by port id.
    @Published public private(set) var portPeaks: [MIDIPort.ID: Double] = [:]
    /// Number of M8U/M4U eX units currently discovered.
    @Published public private(set) var connectedUnitCount: Int = 0
    /// True when at least one M8U eX is physically online.
    @Published public private(set) var hardwareOnline: Bool = false
    /// Recent events for the monitor, newest last.
    @Published public private(set) var monitorEvents: [MonitoredEvent] = []
    /// Aggregate counters.
    @Published public private(set) var totalMessages: UInt64 = 0
    @Published public private(set) var totalDropped: UInt64 = 0
    /// Timestamp of the most recent message on any port.
    @Published public private(set) var lastActivityAt: UInt64 = 0
    /// Average tempo over the last 2 s, derived from MIDI clock. Nil when no clock
    /// is running, so the UI can distinguish "stopped" from a real 0 BPM.
    @Published public private(set) var averageBPM: Double?
    /// Clock pulses currently inside the averaging window.
    @Published public private(set) var clockPulseCount: Int = 0
    /// True while clock is arriving.
    @Published public private(set) var clockIsRunning: Bool = false

    /// Tempo is measured here rather than in the view, so the average is computed
    /// from CoreMIDI's sample-accurate timestamps instead of from UI refresh timing.
    public let clockMonitor = ClockMonitor(window: 2.0)

    /// The socket the tempo readout listens to.
    ///
    /// Port 1 by convention: on both interfaces socket 1 is the designated input in
    /// the hardware's thru and merge modes, and it is where a master keyboard or
    /// sequencer is normally patched. Change it with `setTempoSource(socket:unit:)`.
    public private(set) var tempoSourcePortID: MIDIPort.ID?
    /// Human-readable status of the CoreMIDI client.
    @Published public private(set) var statusLine: String = "Starting…"
    /// Non-fatal problems worth surfacing to the user.
    @Published public private(set) var issues: [String] = []
    /// External (non-M8U) endpoints available for routing.
    @Published public private(set) var externalPorts: [MIDIPort] = []

    // MARK: Configuration (owned by the store, applied here)

    /// Active routes. Replaced wholesale when a profile loads.
    public var routes: [Route] = [] {
        didSet { rebuildRouteIndex() }
    }
    /// Per-port user configuration (labels, notes, hidden flag).
    public var portConfigs: [MIDIPort.ID: PortConfig] = [:] {
        didSet { applyPortConfigs() }
    }
    /// When true the monitor records events; when false the read path skips logging.
    public var monitorEnabled: Bool = true
    /// Maximum number of monitor events retained.
    public var monitorCapacity: Int = 4000
    /// Sources currently being monitored explicitly (unused sources are still
    /// connected so the dashboard can show their activity).
    public var monitorPortFilter: Set<MIDIPort.ID> = []

    // MARK: CoreMIDI objects

    private var client = MIDIClientRef(0)
    private var inputPort = MIDIPortRef(0)
    private var outputPort = MIDIPortRef(0)
    private var virtualSource = MIDIEndpointRef(0)
    private var virtualDestination = MIDIEndpointRef(0)
    private let virtualSourceName = "M8U eX Control Centre Out"
    private let virtualDestinationName = "M8U eX Control Centre In"

    // MARK: Internals

    private let workQueue = DispatchQueue(label: "is.nnv.m8uex.engine.work", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "is.nnv.m8uex.engine.state")
    private var runtimes: [MIDIPort.ID: PortRuntime] = [:]
    /// Routes grouped by source for O(1) dispatch.
    ///
    /// Guarded by `indexLock` because `routes` is edited on the main thread while
    /// the MIDI path reads this on `workQueue`.
    private var routesBySource: [MIDIPort.ID: [Route]] = [:]
    private var routesByDestination: [MIDIPort.ID: [Route]] = [:]
    /// Protects the routing dispatch index. Held only for dictionary swaps and
    /// lookups, never across a MIDI send.
    private let indexLock = NSLock()
    /// Endpoints we are currently connected to, so re-scans do not double-connect.
    private var connectedSourceIDs = Set<MIDIUniqueID>()
    /// Synthetic ports registered by `--selftest`. They are not part of the
    /// CoreMIDI graph, so a rescan must carry them across rather than discard
    /// them — otherwise a rescan triggered mid-test silently removes the very
    /// endpoints the test is exercising.
    private var injectedPorts: [MIDIPort.ID: MIDIPort] = [:]
    /// Maps every port identity in the graph, plus name-and-socket fallbacks, so
    /// a rig saved before a replug still points at the right sockets.
    private var resolver = PortResolver()
    /// Maps a CoreMIDI source's unique id back to our logical port.
    private var sourceIDToPort: [MIDIUniqueID: MIDIPort.ID] = [:]
    /// Small, always-positive tokens used as the `connRefCon` for each source
    /// connection. CoreMIDI hands this value straight back to us in the read
    /// block as a raw pointer, so it must never be a value we dereference — a
    /// monotonically increasing counter is the only safe choice.
    private var connectionTokenToSourceID: [Int: MIDIUniqueID] = [:]
    private var sourceIDToConnectionToken: [MIDIUniqueID: Int] = [:]
    private var nextConnectionToken = 1
    private var portByID: [MIDIPort.ID: MIDIPort] = [:]
    private var nextEventID: UInt64 = 1
    private var monitorBuffer: [MonitoredEvent] = []
    private var uiRefreshTimer: DispatchSourceTimer?
    private var isRunning = false
    /// Counts every successful `MIDISend`, so diagnostics can distinguish "the
    /// route never fired" from "it fired but the destination did not receive".
    private var sendAttemptCount: UInt64 = 0
    private var sendFailureCount: UInt64 = 0

    public init() {}

    // MARK: - Lifecycle

    /// Brings up the CoreMIDI client, creates our virtual endpoints, seeds
    /// ports and starts the UI refresh timer. Safe to call once.
    public func start() {
        stateQueue.sync {
            guard !isRunning else { return }
            isRunning = true
        }

        let name = "M8U eX Control Centre" as CFString
        var status = MIDIClientCreateWithBlock(name, &client) { [weak self] notification in
            guard let self else { return }
            let messageID = notification.pointee.messageID
            if messageID == .msgSetupChanged {
                // The device graph changed: rescan, reconnect, republish.
                self.workQueue.async { self.rescan() }
            }
        }
        guard status == noErr else {
            reportIssue("Could not create the CoreMIDI client (error \(status)). MIDI will not work.")
            return
        }

        status = MIDIInputPortCreateWithBlock(client, "M8U eX Control Centre Input" as CFString, &inputPort) {
            [weak self] packetList, sourceConnectionRefCon in
            guard let self else { return }
            // Hot path. Extract bytes and the source identity, then hand off.
            // The refCon is a token we minted at connect time; it is not a pointer.
            let token = Int(bitPattern: sourceConnectionRefCon)
            self.receive(packetList: packetList, connectionToken: token)
        }
        guard status == noErr else {
            reportIssue("Could not create the MIDI input port (error \(status)). Input monitoring is disabled.")
            return
        }

        status = MIDIOutputPortCreate(client, "M8U eX Control Centre Output" as CFString, &outputPort)
        guard status == noErr else {
            reportIssue("Could not create the MIDI output port (error \(status)). Routing is disabled.")
            return
        }

        createVirtualEndpoints()
        workQueue.async { [weak self] in
            self?.rescan()
            self?.startUIRefresh()
        }
    }

    public func stop() {
        uiRefreshTimer?.cancel()
        uiRefreshTimer = nil
        if client != 0 { MIDIClientDispose(client) }
        client = 0
        inputPort = 0
        outputPort = 0
        virtualSource = 0
        virtualDestination = 0
    }

    deinit {
        uiRefreshTimer?.cancel()
        if client != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Virtual endpoints

    /// Publishes this app as a MIDI device so a DAW, or even another instance
    /// of this app, can route through the patchbay.
    private func createVirtualEndpoints() {
        var status = MIDISourceCreate(client, virtualSourceName as CFString, &virtualSource)
        if status != noErr {
            reportIssue("Could not publish the virtual output port (error \(status)).")
            virtualSource = 0
        }
        status = MIDIDestinationCreateWithBlock(client, virtualDestinationName as CFString, &virtualDestination) {
            [weak self] packetList, _ in
            guard let self else { return }
            self.receive(packetList: packetList, connectionToken: 0)
        }
        if status != noErr {
            reportIssue("Could not publish the virtual input port (error \(status)).")
            virtualDestination = 0
        }
    }

    // MARK: - Discovery

    /// Rebuilds the port list from the current CoreMIDI graph and connects to
    /// any newly appeared sources.
    private func rescan() {
        let m8uPorts = MIDIEndpointEnumerator.m8uPorts()
        let m8uEndpointIDs = Set(
            m8uPorts.flatMap { [$0.source?.uniqueID, $0.destination?.uniqueID].compactMap { $0 } }
        )
        let externals = MIDIEndpointEnumerator.otherPorts(excluding: m8uEndpointIDs)

        var allPorts = m8uPorts
        // Our own virtual endpoints appear in the external list; present them as
        // first-class ports so they can be patched like hardware.
        allPorts.append(contentsOf: externals)
        // Anything registered for testing survives a rescan.
        allPorts.append(contentsOf: injectedPorts.values.filter { port in
            !allPorts.contains { $0.id == port.id }
        })

        // Any unit present at all, even offline, tells us hardware was seen.
        // Counted by CoreMIDI device ID, so an M8U eX plus an M4U eX reports two
        // units rather than collapsing into one.
        let unitCount = Set(m8uPorts.compactMap { $0.id.deviceUID }).count
        let anyOnline = m8uPorts.contains { port in
            (port.source.map { !$0.offline } ?? false) || (port.destination.map { !$0.offline } ?? false)
        }

        // Preserve existing runtime stats across rescans so counters do not reset
        // when an unrelated device is plugged in.
        var newRuntimes: [MIDIPort.ID: PortRuntime] = [:]
        var newSourceMap: [MIDIUniqueID: MIDIPort.ID] = [:]
        var portsByID: [MIDIPort.ID: MIDIPort] = [:]

        for var port in allPorts {
            if let existing = runtimes[port.id] {
                port.direction = existing.port.direction
                port.enabled = existing.port.enabled
                newRuntimes[port.id] = existing
                existing.portSource = port.source
                existing.portDestination = port.destination
            } else {
                newRuntimes[port.id] = PortRuntime(port: port)
            }
            if let source = port.source { newSourceMap[source.uniqueID] = port.id }
            portsByID[port.id] = port
        }

        for (id, runtime) in newRuntimes {
            if let port = portsByID[id] { applyPortConfig(portConfigs[id], to: runtime, basePort: port) }
        }

        // Connect to every source we are not already listening to. We listen to
        // everything so the dashboard can show which socket is live even when the
        // user has not routed it anywhere.
        for port in allPorts {
            guard let source = port.source else { continue }
            guard !connectedSourceIDs.contains(source.uniqueID) else { continue }
            let token = nextConnectionToken
            // The refCon is a bare token CoreMIDI echoes back to us; it is never
            // dereferenced, so a small non-zero integer is safe and unambiguous.
            let context = UnsafeMutableRawPointer(bitPattern: token)
            let status = MIDIPortConnectSource(inputPort, source.endpoint, context)
            if status == noErr {
                nextConnectionToken += 1
                connectedSourceIDs.insert(source.uniqueID)
                connectionTokenToSourceID[token] = source.uniqueID
                sourceIDToConnectionToken[source.uniqueID] = token
            } else {
                reportIssue("Could not listen to “\(source.name)” (error \(status)).")
            }
        }

        let orderedPorts = allPorts.enumerated()
            .sorted { lhs, rhs in
                let l = newRuntimes[lhs.element.id]?.port ?? lhs.element
                let r = newRuntimes[rhs.element.id]?.port ?? rhs.element
                if l.sortKey != r.sortKey { return l.sortKey < r.sortKey }
                return lhs.offset < rhs.offset
            }
            .map { newRuntimes[$0.element.id]?.port ?? $0.element }

        let finalPorts = orderedPorts
        let finalRuntimes = newRuntimes
        let finalSourceMap = newSourceMap
        let finalExternals = externals
        // Rebuilt on every rescan so route resolution reflects what is actually
        // connected right now.
        let finalResolver = PortResolver(ports: allPorts)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.workQueue.sync {
                self.runtimes = finalRuntimes
                self.sourceIDToPort = finalSourceMap
                self.portByID = portsByID
                self.resolver = finalResolver
            }
            self.ports = finalPorts
            self.externalPorts = finalExternals
            self.resolveTempoSource()
            // Remember the friendly name of every external endpoint so a route to
            // one can be re-matched by name after a replug.
            for port in finalPorts where !port.isM8UPhysical {
                self.externalPortNames[port.id] = port.label
            }
            self.connectedUnitCount = unitCount
            self.hardwareOnline = anyOnline
            self.rebuildRouteIndex()
            self.updateStatusLine()
        }
    }

    private func updateStatusLine() {
        if hardwareOnline {
            let sockets = ports.filter { $0.isM8UPhysical }.count
            statusLine = connectedUnitCount > 1
                ? "\(connectedUnitCount) interfaces online · \(sockets) ports"
                : "Interface online · \(sockets) ports"
        } else if connectedUnitCount > 0 {
            statusLine = "Interface remembered but offline — check the USB cable"
        } else {
            statusLine = "No M8U eX detected"
        }
    }

    // MARK: - Configuration

    private func applyPortConfig(_ config: PortConfig?, to runtime: PortRuntime, basePort: MIDIPort) {
        var port = basePort
        if let config {
            if !config.customLabel.isEmpty { port.label = config.customLabel }
            port.enabled = !config.hidden
        }
        runtime.updatePort(port)
    }

    /// Re-applies labels and enabled flags after the user edits them.
    ///
    /// The fallback label is the port's default from the enumerator, not
    /// `shortName` — that keeps the interface name in front ("ESI M4U eX · Port 3")
    /// so two connected units are still distinguishable.
    private func applyPortConfigs() {
        workQueue.async { [weak self] in
            guard let self else { return }
            var updated: [MIDIPort] = []
            for (_, runtime) in self.runtimes {
                let base = runtime.port
                var port = base
                // Try the exact identity first, then fall back to name-and-socket
                // so a renamed port survives the device getting a new CoreMIDI ID.
                let config = self.portConfigs[base.id] ?? self.resolver.resolve(base.id).flatMap { self.portConfigs[$0] }
                if let config, !config.customLabel.isEmpty {
                    port.label = config.customLabel
                    port.enabled = !config.hidden
                } else {
                    port.label = base.label
                    port.enabled = !(config?.hidden ?? false)
                }
                runtime.updatePort(port)
                updated.append(port)
            }
            updated.sort { $0.sortKey < $1.sortKey }
            DispatchQueue.main.async { self.ports = updated }
        }
    }

    /// Rebuilds the dispatch index.
    ///
    /// `routes` is written from the main thread (the UI edits it) and read from
    /// the work queue (the MIDI path). Publishing the index through a lock rather
    /// than through an async block on the work queue makes an edit visible to the
    /// very next message, instead of whenever that queue happens to get to it.
    private func rebuildRouteIndex() {
        rebuildRouteIndexLocked(routes)
    }

    /// Must be called on `workQueue`.
    private func rebuildRouteIndexLocked(_ snapshot: [Route]) {
        var bySource: [MIDIPort.ID: [Route]] = [:]
        var byDestination: [MIDIPort.ID: [Route]] = [:]
        for route in snapshot where route.isEnabled {
            bySource[route.sourcePortID, default: []].append(route)
            byDestination[route.destinationPortID, default: []].append(route)
        }
        indexLock.lock()
        routesBySource = bySource
        routesByDestination = byDestination
        indexLock.unlock()
    }

    /// Routes that use the given port, in either direction.
    public func routes(touching portID: MIDIPort.ID) -> [Route] {
        routes.filter { $0.sourcePortID == portID || $0.destinationPortID == portID }
    }

    /// Adds a route, or enables the existing equivalent route rather than
    /// creating a duplicate connection.
    @discardableResult
    public func addRoute(from source: MIDIPort.ID, to destination: MIDIPort.ID) -> Route {
        if let index = routes.firstIndex(where: {
            $0.sourcePortID == source && $0.destinationPortID == destination
        }) {
            if !routes[index].isEnabled {
                routes[index].isEnabled = true
                let reactivated = routes[index]
                rebuildRouteIndex()
                return reactivated
            }
            return routes[index]
        }
        let route = Route(sourcePortID: source, destinationPortID: destination)
        routes.append(route)
        rebuildRouteIndex()
        return route
    }

    /// Removes every route between a pair of ports.
    public func removeRoutes(from source: MIDIPort.ID, to destination: MIDIPort.ID) {
        let removed = routes.filter { $0.sourcePortID == source && $0.destinationPortID == destination }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        routes.removeAll { removedIDs.contains($0.id) }
        rebuildRouteIndex()
    }

    /// Applies an edit to one route in place.
    public func updateRoute(_ route: Route) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index] = route
        rebuildRouteIndex()
    }

    /// Replaces the entire routing table, used when a rig profile is loaded.
    public func replaceRoutes(_ newRoutes: [Route]) {
        routes = newRoutes
    }

    /// Disconnects every source. Called on quit so no MIDI is left half-routed
    /// if the process is force-quit while a route is live.
    public func disconnectAll() {
        workQueue.sync {
            for uniqueID in connectedSourceIDs {
                guard let endpoint = sourceEndpointLocked(forUniqueID: uniqueID) else { continue }
                MIDIPortDisconnectSource(inputPort, endpoint)
            }
            connectedSourceIDs.removeAll()
            connectionTokenToSourceID.removeAll()
            sourceIDToConnectionToken.removeAll()
        }
    }

    /// Must be called on `workQueue`.
    private func sourceEndpointLocked(forUniqueID uniqueID: MIDIUniqueID) -> MIDIEndpointRef? {
        for runtime in runtimes.values where runtime.port.source?.uniqueID == uniqueID {
            return runtime.port.source?.endpoint
        }
        return nil
    }

    // MARK: - Receive path

    /// Called from the CoreMIDI read block. Must return quickly: the packet list
    /// is only valid for the duration of this call, so it is drained immediately
    /// and the bytes are handed to the work queue.
    private func receive(packetList: UnsafePointer<MIDIPacketList>, connectionToken: Int) {
        let chunks = MIDIPacketBridge.drain(packetList: packetList)
        guard !chunks.isEmpty else { return }

        workQueue.async { [weak self] in
            self?.process(chunks: chunks, connectionToken: connectionToken)
        }
    }

    /// Parsing, statistics and routing, all on the serial work queue.
    private func process(chunks: [MIDIPacketChunk], connectionToken: Int) {
        guard let sourceUniqueID = connectionTokenToSourceID[connectionToken],
              let sourcePortID = sourceIDToPort[sourceUniqueID] else {
            // Token 0 is our own virtual destination; anything unrecognised is
            // ignored rather than guessed at, so a mis-mapped refCon can never
            // create a feedback loop.
            return
        }
        guard let runtime = runtimes[sourcePortID] else { return }

        var produced: [MIDIMessage] = []
        var anomalies: [MIDIByteStreamParser.Anomaly] = []
        for chunk in chunks {
            let result = runtime.parser.parse(chunk.bytes, timestamp: chunk.timestamp)
            produced.append(contentsOf: result.messages)
            anomalies.append(contentsOf: result.anomalies)
        }

        guard !produced.isEmpty || !anomalies.isEmpty else { return }

        let now = MIDITime.hostTime()
        var events: [MonitoredEvent] = []
        /// Messages that actually went out each destination socket, so their
        /// counters reflect what the socket carried rather than what a route
        /// merely intended to send.
        var outputSink: [MIDIPort.ID: [MIDIMessage]] = [:]

        for message in produced {
            // Tempo is taken from the raw stream, before any route filtering, so a
            // clock the user has chosen not to forward still drives the display.
            if message.status == 0xF8 {
                clockMonitor.record(at: message.timestamp, portID: sourcePortID)
            }
            runtime.stats.record(message)
            runtime.meter.add(1, at: now)
            // The front panel lights green for input. Observed input traffic is
            // the only evidence macOS gets about auto-detected direction.
            if runtime.port.direction != .input {
                runtime.setDirection(.input)
            }
            if monitorEnabled {
                events.append(makeEvent(message: message, portID: sourcePortID, label: runtime.port.label,
                                        direction: .input, routeID: nil))
            }
            // Fan out through the patchbay.
            if let fanout = fanoutRoutes(from: sourcePortID) {
                for route in fanout {
                    for transformed in route.process(message) {
                        guard let destination = resolvedDestination(for: route.destinationPortID) else { continue }
                        send(transformed.bytes, to: destination, timestamp: transformed.timestamp)
                        // What the destination socket actually carried, which is
                        // what an output LED's counters should show.
                        outputSink[route.destinationPortID, default: []].append(transformed)
                        if monitorEnabled {
                            events.append(makeEvent(message: transformed, portID: route.destinationPortID,
                                                    label: label(for: route.destinationPortID),
                                                    direction: .output, routeID: route.id))
                        }
                    }
                }
            }
        }

        // Record output-side statistics and direction on the destination ports.
        for (portID, messages) in outputSink {
            guard let destinationRuntime = runtimes[portID] else { continue }
            destinationRuntime.meter.add(UInt64(messages.count), at: now)
            for message in messages {
                destinationRuntime.stats.record(message)
            }
            if destinationRuntime.port.direction != .output {
                destinationRuntime.setDirection(.output)
            }
        }

        if !anomalies.isEmpty {
            runtime.stats.anomalyCount &+= UInt64(anomalies.count)
        }

        let totalProduced = UInt64(produced.count)
        let capturedEvents = events
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.totalMessages &+= totalProduced
            self.lastActivityAt = now
            if self.monitorEnabled, !capturedEvents.isEmpty {
                self.appendMonitorEvents(capturedEvents)
            }
        }
    }

    /// The routes leaving a source port. Takes the index lock only for the
    /// dictionary lookup, then works on the returned (value-type) copy.
    private func fanoutRoutes(from portID: MIDIPort.ID) -> [Route]? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return routesBySource[portID]
    }

    /// The routes arriving at a destination port.
    private func incomingRoutes(to portID: MIDIPort.ID) -> [Route]? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return routesByDestination[portID]
    }

    private func makeEvent(
        message: MIDIMessage,
        portID: MIDIPort.ID,
        label: String,
        direction: PortDirection,
        routeID: UUID?
    ) -> MonitoredEvent {
        let id = nextEventID
        nextEventID &+= 1
        return MonitoredEvent(
            id: id,
            timestamp: message.timestamp,
            portID: portID,
            portLabel: label,
            direction: direction,
            message: message,
            routeID: routeID
        )
    }

    private func label(for portID: MIDIPort.ID) -> String {
        runtimes[portID]?.port.label ?? portID.shortName
    }

    /// The endpoint to send to for a route's destination.
    ///
    /// A route stores the identity it was created with. If the device has since
    /// been replugged and picked up a new CoreMIDI ID, the fallback keeps the route
    /// pointing at the same socket or device instead of silently going dead.
    private func resolvedDestination(for portID: MIDIPort.ID) -> MIDIEndpointRef? {
        let live = runtimes[portID] != nil ? portID : resolvedLivePort(for: portID)
        guard let live, let runtime = runtimes[live] else { return nil }
        guard runtime.port.enabled else { return nil }
        return runtime.port.destination?.endpoint
    }

    /// Resolves a saved route endpoint to the live port that should serve it.
    ///
    /// Tries the exact identity first. Failing that, the resolver matches by device
    /// name (for the interfaces) or by endpoint name (for external devices), so a
    /// route survives a replug that changes a CoreMIDI ID.
    private func resolvedLivePort(for portID: MIDIPort.ID) -> MIDIPort.ID? {
        if let exact = resolver.resolve(portID) { return exact }
        if let label = savedLabel(for: portID) {
            return resolver.resolve(portID, label: label)
        }
        return nil
    }

    /// Names of external endpoints, remembered so routes to them survive a replug
    /// that changes their CoreMIDI ID.
    public var externalPortNames: [MIDIPort.ID: String] = [:]

    /// A human label previously recorded for a port identity, if any.
    private func savedLabel(for portID: MIDIPort.ID) -> String? {
        if let config = portConfigs[portID], !config.customLabel.isEmpty { return config.customLabel }
        return externalPortNames[portID]
    }

    // MARK: - Send path

    /// Packs raw MIDI 1.0 bytes into a packet list and sends them.
    ///
    /// Timestamps of `0` mean "send now", which is what we want for routed
    /// traffic: the data already arrived, and CoreMIDI will stamp it.
    private func send(_ bytes: [UInt8], to destination: MIDIEndpointRef, timestamp: UInt64) {
        guard !bytes.isEmpty, outputPort != 0 else { return }
        // A single MIDI 1.0 message cannot exceed 256 bytes. Anything larger is
        // malformed or a file dump, and is dropped rather than truncated.
        guard bytes.count <= 256 else {
            DispatchQueue.main.async { [weak self] in
                self?.totalDropped &+= 1
            }
            return
        }

        let status = MIDIPacketBridge.send(
            bytes: bytes,
            to: destination,
            via: outputPort,
            timestamp: timestamp
        )
        if status != noErr {
            sendFailureCount &+= 1
            DispatchQueue.main.async { [weak self] in
                self?.totalDropped &+= 1
            }
        } else {
            sendAttemptCount &+= 1
        }
    }

    /// Sends a message through the app's own virtual source so other software
    /// (a DAW, say) can receive it. Used by the inspector's test-message button.
    public func sendToVirtualSource(_ bytes: [UInt8]) {
        guard virtualSource != 0, !bytes.isEmpty, bytes.count <= 256 else { return }
        MIDIPacketBridge.publish(bytes: bytes, from: virtualSource)
    }

    /// Sends a test message directly to one logical port's destination.
    public func sendTestMessage(_ bytes: [UInt8], to portID: MIDIPort.ID) {
        workQueue.async { [weak self] in
            guard let self, let destination = self.resolvedDestination(for: portID) else { return }
            self.send(bytes, to: destination, timestamp: 0)
            if let runtime = self.runtimes[portID] {
                runtime.meter.add(1, at: MIDITime.hostTime())
                runtime.setDirection(.output)
            }
        }
    }

    // MARK: - Monitor

    private func appendMonitorEvents(_ events: [MonitoredEvent]) {
        monitorBuffer.append(contentsOf: events)
        let overflow = monitorBuffer.count - monitorCapacity
        if overflow > 0 {
            monitorBuffer.removeFirst(overflow)
        }
        monitorEvents = monitorBuffer
    }

    public func clearMonitor() {
        monitorBuffer.removeAll(keepingCapacity: true)
        monitorEvents = []
    }

    /// Clears all traffic counters and meters but keeps ports and routes.
    public func resetStatistics() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.clockMonitor.reset()
            for (_, runtime) in self.runtimes {
                runtime.stats = PortStats()
                runtime.meter.reset()
                runtime.parser.reset()
                runtime.level = 0
                runtime.peakLevel = 0
            }
            DispatchQueue.main.async {
                self.totalMessages = 0
                self.totalDropped = 0
                self.portStats = [:]
                self.portLevels = [:]
                self.portPeaks = [:]
            }
        }
    }

    // MARK: - UI refresh

    /// Publishes a consistent snapshot of all live counters ~20 times a second.
    /// Updating per message would swamp the main thread at high MIDI rates.
    private func startUIRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.publishSnapshot()
        }
        timer.resume()
        uiRefreshTimer = timer
    }

    private func publishSnapshot() {
        let now = MIDITime.hostTime()
        let bpm = clockMonitor.averageBPM(now: now)
        let pulses = clockMonitor.pulseCount(now: now)
        let running = clockMonitor.isRunning(now: now)
        var stats: [MIDIPort.ID: PortStats] = [:]
        var levels: [MIDIPort.ID: Double] = [:]
        var peaks: [MIDIPort.ID: Double] = [:]
        var directions: [MIDIPort.ID: PortDirection] = [:]

        stats.reserveCapacity(runtimes.count)
        for (id, runtime) in runtimes {
            var snapshot = runtime.stats
            let rate = runtime.meter.rate(at: now)
            snapshot.messagesPerSecond = rate
            snapshot.peakMessagesPerSecond = max(snapshot.peakMessagesPerSecond, rate)
            runtime.stats.peakMessagesPerSecond = snapshot.peakMessagesPerSecond

            // Full-scale for the meter: 500 msg/s is a busy single MIDI cable.
            // Any more than that and we simply show a full bar.
            let level = runtime.meter.normalized(at: now, fullScale: 500)
            runtime.level = level
            // Peak hold with a slow decay so short bursts stay visible.
            runtime.peakLevel = max(level, runtime.peakLevel * 0.94)

            stats[id] = snapshot
            levels[id] = level
            peaks[id] = runtime.peakLevel
            directions[id] = runtime.port.direction
        }

        let liveDirections = directions
        let liveStats = stats
        let liveLevels = levels
        let livePeaks = peaks

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.portStats = liveStats
            self.portLevels = liveLevels
            self.portPeaks = livePeaks
            self.averageBPM = bpm
            self.clockPulseCount = pulses
            self.clockIsRunning = running
            // Reflect observed directions back onto the published ports.
            if !liveDirections.isEmpty {
                self.ports = self.ports.map { port in
                    guard let direction = liveDirections[port.id] else { return port }
                    guard port.direction != direction else { return port }
                    var updated = port
                    updated.direction = direction
                    return updated
                }
            }
        }
    }

    // MARK: - Issues

    private func reportIssue(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.issues.contains(text) { self.issues.append(text) }
        }
    }

    /// Forces a rediscovery, exposed for the Refresh button.
    public func refresh() {
        workQueue.async { [weak self] in
            self?.rescan()
        }
    }

    // MARK: - Port access helpers

    public func port(withID id: MIDIPort.ID) -> MIDIPort? {
        ports.first { $0.id == id }
    }

    /// Points the tempo readout at a socket, or at no single socket.
    public func setTempoSource(socket: Int?, unitNameFragment: String = "M8U") {
        workQueue.async { [weak self] in
            guard let self else { return }
            if let socket,
               let port = self.runtimes.values.first(where: { runtime in
                   runtime.port.m8uIndex == socket
                       && (runtime.port.unitName?.contains(unitNameFragment) ?? false)
               }) {
                self.clockMonitor.preferredPortID = port.portID
                self.tempoSourcePortID = port.portID
            } else {
                self.clockMonitor.preferredPortID = nil
                self.tempoSourcePortID = nil
            }
        }
    }

    /// Re-points the tempo source at the live port after the graph is rebuilt, since
    /// a rescan can hand the interface a new unique ID.
    private func resolveTempoSource() {
        guard let wanted = tempoSourcePortID ?? defaultTempoSourceID() else { return }
        let live = resolver.resolve(wanted) ?? wanted
        if runtimes[live] != nil {
            clockMonitor.preferredPortID = live
            tempoSourcePortID = live
        }
    }

    /// Socket 1 of the M8U eX, falling back to any interface's socket 1.
    private func defaultTempoSourceID() -> MIDIPort.ID? {
        let candidates = runtimes.values.map(\.port)
        let socketOne = candidates.filter { $0.m8uIndex == 1 }
        return (socketOne.first { $0.unitName?.contains("M8U") ?? false } ?? socketOne.first)?.id
    }

    /// The M8U ports only, in socket order.
    public var m8uPorts: [MIDIPort] {
        ports.filter { $0.isM8UPhysical }.sorted { $0.sortKey < $1.sortKey }
    }

    /// Which routes are exclusive to the given destination, for the inspector.
    public func hasActiveRoute(from sourceID: MIDIPort.ID, to destinationID: MIDIPort.ID) -> Bool {
        routes.contains { $0.sourcePortID == sourceID && $0.destinationPortID == destinationID && $0.isEnabled }
    }

    /// The route between two ports, if one exists, enabled or not.
    public func route(from sourceID: MIDIPort.ID, to destinationID: MIDIPort.ID) -> Route? {
        routes.first { $0.sourcePortID == sourceID && $0.destinationPortID == destinationID }
    }

    // MARK: - Test support

    /// Registers a synthetic source/destination pair with the engine and opens
    /// the bookkeeping needed for its traffic to flow.
    ///
    /// Used by `--selftest` to exercise the real receive, route and send paths
    /// with a virtual loopback standing in for the interface. Nothing in the
    /// shipping UI calls this.
    public func registerTestPorts(source: MIDIPort, destination: MIDIPort) {
        workQueue.sync {
            let token = nextConnectionToken
            nextConnectionToken += 1

            if let sourceInfo = source.source {
                connectionTokenToSourceID[token] = sourceInfo.uniqueID
                sourceIDToConnectionToken[sourceInfo.uniqueID] = token
                sourceIDToPort[sourceInfo.uniqueID] = source.id
            }
            runtimes[source.id] = PortRuntime(port: source)
            runtimes[destination.id] = PortRuntime(port: destination)
            portByID[source.id] = source
            portByID[destination.id] = destination
            // Remember them so a later rescan does not drop them.
            injectedPorts[source.id] = source
            injectedPorts[destination.id] = destination
            rebuildRouteIndexLocked(routes)

            // Publish on the main queue only after the work queue has been
            // released. Publishing *inside* the workQueue.sync block would need
            // DispatchQueue.main.sync and deadlock the instant a caller on the
            // main thread is waiting for that very block to finish.
            let combined = ports + [source, destination]
            DispatchQueue.main.async { [weak self] in
                self?.ports = combined
            }
        }
    }

    /// Feeds bytes into the engine as though they had arrived from `fromPort`.
    ///
    /// This goes through the identical parse → filter → transform → send path a
    /// real USB packet takes, so a passing self test means the real pipeline
    /// works, not a parallel test-only implementation.
    public func injectForTesting(bytes: [UInt8], fromPort portID: MIDIPort.ID) {
        workQueue.async { [weak self] in
            guard let self, let token = self.token(for: portID) else { return }
            let chunk = MIDIPacketChunk(bytes: bytes, timestamp: MIDITime.hostTime())
            self.process(chunks: [chunk], connectionToken: token)
        }
    }

    /// The connection token registered for a logical port, if any.
    private func token(for portID: MIDIPort.ID) -> Int? {
        guard let uniqueID = runtimes[portID]?.port.source?.uniqueID else { return nil }
        return sourceIDToConnectionToken[uniqueID]
    }

    /// Reads a port's live counters directly from the work queue.
    ///
    /// The `@Published` snapshot updates about twenty times a second, which is
    /// right for drawing but too slow and too racy for a test that has just
    /// injected a message. This returns the authoritative value.
    public func liveStats(for portID: MIDIPort.ID) -> PortStats {
        workQueue.sync { runtimes[portID]?.stats ?? PortStats() }
    }

    /// Counts of messages the engine has actually transmitted, and of sends that
    /// failed. Lets a diagnostic prove a route fired without needing to observe
    /// the far end, which is impossible when the destination is real hardware.
    public func transmissionCounts() -> (sent: UInt64, failed: UInt64) {
        workQueue.sync { (sendAttemptCount, sendFailureCount) }
    }

    /// Blocks until every block already queued on the work queue has run.
    ///
    /// The engine is deliberately asynchronous — the CoreMIDI read block must
    /// return immediately — so a test that injects a message and then reads a
    /// counter has to drain the queue first. Nothing in the shipping app needs
    /// this; it exists so `--selftest` can make deterministic assertions.
    public func synchronizeForTesting() {
        workQueue.sync {}
    }

    /// Clears a port's byte-stream parser, discarding any running status.
    ///
    /// Running status is stateful by design: a data byte with no status byte
    /// legitimately continues the previous message. A test that wants to prove
    /// "data with no status is reported as malformed" has to start from a parser
    /// that has never seen a status byte.
    public func resetParserForTesting(port portID: MIDIPort.ID) {
        workQueue.sync {
            runtimes[portID]?.parser.reset()
        }
    }

    /// A dump of the engine's internal routing tables, for diagnostics.
    ///
    /// Used by `--selftest` to explain a failure instead of leaving the reader to
    /// guess which of the many moving parts went wrong.
    public func debugRoutingDescription() -> String {
        indexLock.lock()
        let sourceIndex = routesBySource
        indexLock.unlock()

        return workQueue.sync {
            var lines: [String] = []
            lines.append("runtimes: \(runtimes.count), routes: \(routes.count), "
                         + "known sources: \(sourceIDToPort.count)")
            lines.append("sends ok: \(sendAttemptCount), send failures: \(sendFailureCount)")
            for (source, rs) in sourceIndex.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                let enabled = rs.filter(\.isEnabled).count
                lines.append("  source \(source) → \(rs.count) routes (\(enabled) enabled): "
                             + rs.map { route in
                                 let destinationResolved = runtimes[route.destinationPortID]?
                                     .port.destination?.endpoint != nil
                                 return "\(route.destinationPortID)"
                                     + "[enabled=\(route.isEnabled),destResolved=\(destinationResolved),"
                                     + "ch=\(route.channels.rawValue),xf=\(route.transform.summary ?? "none")]"
                             }.joined(separator: " ")
                )
            }
            for (portID, runtime) in runtimes.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                lines.append("  port \(portID): msgs=\(runtime.stats.messageCount) "
                             + "notes=\(runtime.stats.noteOnCount) "
                             + "anomalies=\(runtime.stats.anomalyCount) "
                             + "dir=\(runtime.port.direction.rawValue) "
                             + "source=\(runtime.port.source != nil) "
                             + "dest=\(runtime.port.destination != nil)")
            }
            return lines.joined(separator: "\n")
        }
    }
}

// MARK: - PortRuntime direction and identity

extension PortRuntime {
    /// The port as this runtime currently sees it, including live direction.
    var portSource: EndpointInfo? {
        get { port.source }
        set { port.source = newValue }
    }

    var portDestination: EndpointInfo? {
        get { port.destination }
        set { port.destination = newValue }
    }

    func setDirection(_ direction: PortDirection) {
        port.direction = direction
    }

    func updatePort(_ newPort: MIDIPort) {
        port.label = newPort.label
        port.enabled = newPort.enabled
    }
}
