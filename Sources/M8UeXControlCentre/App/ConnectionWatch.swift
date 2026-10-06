import Foundation
import IOKit
import CoreMIDI

// MARK: - Connection watcher

/// Live view of whether the interfaces are actually attached.
///
/// This exists because "is it connected?" has two independent answers that are
/// easy to confuse:
///
///   1. **USB** — has macOS enumerated the device at all? If not, nothing else
///      can possibly work, and the fault is the cable, the port or the power.
///   2. **CoreMIDI** — has MIDIServer built the MIDI ports? This can only happen
///      after step 1.
///
/// CoreMIDI also keeps *offline cached* entries for devices it has seen before,
/// which look like the interface is present when it is not. Checking USB
/// separately is the only way to tell "plugged in" from "remembered".
///
/// Run as `M8U eX Control Centre --watch`. Plug and unplug while it runs.
enum ConnectionWatch {

    /// ESI Audiotechnik's USB vendor ID.
    private static let esiVendorID = 0x0A92

    /// Device names that indicate the interface even if the vendor ID lookup fails.
    private static let nameMarkers = ["m8u", "m4u", "esi"]

    static func run() -> Int32 {
        print("M8U eX Control Centre — connection watch")
        print(String(repeating: "=", count: 66))
        print("Plug and unplug the interfaces while this runs. Control-C to stop.")
        print("")

        var lastUSB: [String] = []
        var lastMIDI: [String] = []
        var lastUnitSignature = ""

        // An initial read so the first line of output is meaningful immediately.
        lastUSB = usbMIDIDeviceNames()
        lastMIDI = coreMIDIUnitDescriptions()

        report(usb: lastUSB, midi: lastMIDI, isFirst: true)

        while true {
            Thread.sleep(forTimeInterval: 1.0)

            let usb = usbMIDIDeviceNames()
            let midi = coreMIDIUnitDescriptions()
            let signature = midi.joined(separator: "|")

            if usb != lastUSB {
                let added = Set(usb).subtracting(lastUSB)
                let removed = Set(lastUSB).subtracting(usb)
                print("")
                for name in added.sorted() { print("  + USB ATTACHED   \(name)") }
                for name in removed.sorted() { print("  - USB DETACHED   \(name)") }
                lastUSB = usb
            }

            if signature != lastUnitSignature {
                if lastUnitSignature.isEmpty {
                    lastUnitSignature = signature
                } else {
                    print("")
                    print("CoreMIDI setup changed:")
                    for line in midi { print("    \(line)") }
                    lastUnitSignature = signature
                }
            }

            // Re-print the summary whenever the picture changes meaningfully.
            if lastMIDI != midi {
                lastMIDI = midi
                print("")
                report(usb: usb, midi: midi, isFirst: false)
            }
        }
    }

    // MARK: Reporting

    private static func report(usb: [String], midi: [String], isFirst: Bool) {
        if !isFirst { print(String(repeating: "-", count: 66)) }

        print("USB devices that present as MIDI:")
        if usb.isEmpty {
            print("  (none)")
        } else {
            for name in usb { print("  • \(name)") }
        }

        print("")
        print("CoreMIDI interfaces:")
        if midi.isEmpty {
            print("  (none)")
        } else {
            for line in midi { print("  • \(line)") }
        }

        let anyOnline = midi.contains { $0.contains("ONLINE") }
        print("")
        if anyOnline {
            print("STATUS: interface present and online.")
        } else if !usb.isEmpty {
            print("STATUS: USB devices present but no online M8U/M4U eX. "
                  + "CoreMIDI may still be starting up.")
        } else {
            print("STATUS: no ESI interface on USB. Check the cable, the USB HOST socket")
            print("        on the back of the unit, and that the 5V supply is connected.")
        }
        print("")
    }

    // MARK: USB enumeration

    /// Names of USB devices that look like MIDI interfaces, or that are ESI.
    ///
    /// Read straight from the IORegistry rather than `system_profiler`, which
    /// needs a long-running helper and can return nothing at all in a restricted
    /// environment — silently looking like "no hardware".
    private static func usbMIDIDeviceNames() -> [String] {
        var names: Set<String> = []

        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            let vendor = integerProperty(service, "idVendor") ?? 0
            let product = integerProperty(service, "idProduct") ?? 0
            let name = stringProperty(service, "USB Product Name")
                ?? stringProperty(service, "kUSBProductString")
                ?? "Unknown"

            let isESI = vendor == esiVendorID
            let looksLikeInterface = nameMarkers.contains { name.lowercased().contains($0) }
            // USB audio/MIDI class devices are worth listing too, since a MIDI
            // interface could in principle be bridged through one.
            let isAudioClass = (integerProperty(service, "bInterfaceClass") ?? 0) == 1
                || (integerProperty(service, "bDeviceClass") ?? 0) == 1

            if isESI || looksLikeInterface || isAudioClass {
                let vendorText = String(format: "0x%04X", vendor)
                names.insert("\(name)  [vendor \(vendorText), product \(String(format: "0x%04X", product))]")
            }
        }
        return names.sorted()
    }

    private static func integerProperty(_ service: io_registry_entry_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return value as? String
    }

    // MARK: CoreMIDI enumeration

    /// One line per ESI interface, stating plainly whether it is online.
    private static func coreMIDIUnitDescriptions() -> [String] {
        var lines: [String] = []

        for index in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(index)
            let name = MIDIObject.name(device)
            guard M8UeXDiscovery.matches(deviceName: name) else { continue }

            let entityCount = MIDIDeviceGetNumberOfEntities(device)

            // A device counts as online only if one of its endpoints is not offline.
            var online = false
            var socketCount = 0
            for entityIndex in 0..<entityCount {
                let entity = MIDIDeviceGetEntity(device, entityIndex)
                for sourceIndex in 0..<MIDIEntityGetNumberOfSources(entity) {
                    socketCount += 0
                    if !MIDIObject.isOffline(MIDIEntityGetSource(entity, sourceIndex)) { online = true }
                }
                for destinationIndex in 0..<MIDIEntityGetNumberOfDestinations(entity) {
                    if !MIDIObject.isOffline(MIDIEntityGetDestination(entity, destinationIndex)) { online = true }
                }
                if M8UeXDiscovery.portIndex(fromEntityName: MIDIObject.name(entity)) != nil {
                    socketCount += 1
                }
            }
            let deviceOnline = !MIDIObject.isOffline(device) || online

            let uid = MIDIObject.uniqueID(device) ?? 0
            let state = deviceOnline ? "ONLINE" : "offline (cached — not currently connected)"
            lines.append("\(name) — \(socketCount) sockets, deviceUID \(uid) — \(state)")
        }

        return lines
    }
}
