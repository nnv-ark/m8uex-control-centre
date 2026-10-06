# M8U eX Control Centre

A native macOS app for the **ESI M8U eX** (16-port) and **ESI M4U eX** (8-port)
USB MIDI interfaces. Both units can be connected at the same time.

## Why this exists

These interfaces are **100% class compliant**: macOS publishes all of their MIDI
ports by itself, with no driver, and there is no ESI control-panel application on
any platform. The only Windows download is the *ESI MIDI Port* driver, which
exists purely because Windows needs help with multi-client and multi-device MIDI
— something CoreMIDI on macOS already does natively.

So there was nothing to port. What was missing is the tool nobody built: a way to
*see* and *control* what a multi-port interface is doing. That is this app.

## Using two interfaces together

An M8U eX and an M4U eX can both be connected. This is worth calling out because
it is the case that breaks naive designs, and the details are not obvious:

- Both units expose entities named **"Port 1"…"Port N"**, so socket number alone
  does **not** identify a port. A port is identified by the pair
  *(interface, socket number)*.
- Ports are labelled with their interface, e.g. `ESI M8U eX · Port 3` versus
  `ESI M4U eX · Port 3`, so the two are never confused in the patchbay.
- The M8U eX has 16 sockets and the M4U eX has 8, so sorting is grouped by
  interface rather than by socket number — otherwise the two units' ports would
  interleave into a confusing order.
- A rig stores both the CoreMIDI device ID and the device name for every port.
  macOS can hand a device a **new** unique ID after a replug or DAC change, so a
  saved rig is re-matched by interface name plus socket number when the exact ID
  no longer exists. Routes therefore survive the units being unplugged, added or
  reconnected in a different order.

The **Hardware** section of the sidebar reports how many units are connected and
the total socket count.

## What it does

| Feature | Notes |
|---|---|
| **Live dashboard** | One tile per socket, mirroring the front-panel LEDs. Green = working as an input, red = output, derived from observed traffic. Includes per-port rate meters, peak hold, channel activity, and totals the hardware cannot show you. |
| **Routing patchbay** | A source × destination matrix. Click a cell to connect or disconnect. Repatch your whole rig without touching a cable. |
| **Per-route filtering** | Channel mask, message-type gates (notes, CC, program change, pitch bend, aftertouch, clock, transport, SysEx), and per-route note range. |
| **Per-route transforms** | Transpose, velocity scale/offset, force channel, CC blocking. |
| **MIDI monitor** | Live log across all 16 ports at once, decoded plus raw hex, filterable by text, direction and port. |
| **Diagnostics** | Per-port health, peak rates, malformed-data counts, MIDI clock tempo estimation, and an honest list of what the app cannot do. |
| **Named ports & rigs** | Call socket 7 "Prophet 6". Save the whole patch as a JSON rig, export it, hand it to another machine. |
| **Panic** | All-notes-off, all-sound-off and sustain-off across every output port. ⌘. |
| **Runs in the background** | Closing the window does not stop routing — the app keeps running with a menu bar item. ⌘Q quits properly. |
| **Launch at login** | Optional, so routing returns automatically after a reboot. |

## Why it can keep running in the background

These interfaces have **no routing of their own while a computer is connected** — the
computer does it. That makes this app the router: if it stops, every route stops with
it, and a window being closed is not a reason to tear the rig down.

Both settings live in **Preferences** (⌘,) and default to the useful state:

- **Keep routing when the window is closed** — on by default. The app stays alive with
  a menu bar item; ⌘Q still quits fully.
- **Start automatically when I log in** — off by default, one click to enable.

If genuinely computer-free standalone routing is what you need, that is a hardware
feature these units do not have. See
[FIRMWARE-INVESTIGATION.md](FIRMWARE-INVESTIGATION.md) for why, with measurements.

## What it deliberately cannot do

The interface's own hardware features are **not** reachable from any computer —
this is a property of the device, not a gap in the app. The Diagnostics view says
so in the UI as well.

| Hardware feature | How it is controlled |
|---|---|
| Standalone Pass-through / Thru / Merge modes | **MODE** button on the front panel. Only active when no computer is connected. |
| Unit A/B addressing | DIP switch 1 |
| MIDI running status | DIP switch 2 |
| USB 2.0 legacy vs 3.0 high-performance | DIP switch 3 |
| Front-panel LED colour | Decided by the device firmware from signal flow |

**Tip:** set DIP switch 3 to ON (USB 3.0 high-performance mode) — the manual
recommends it for current versions of macOS. DIP switches must be changed with
USB *and* power disconnected.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project M8UeXControlCentre.xcodeproj \
           -scheme M8UeXControlCentre \
           -configuration Release \
           -derivedDataPath .build build
```

The app lands in
`.build/Build/Products/Release/M8U eX Control Centre.app`.

> **Note on sandboxes:** the Swift compiler launches a sandboxed macro plugin
> server, which cannot start inside another sandbox. If you are building from
> within a restricted environment, the build needs to run unsandboxed.

## Command line

The app is scriptable. All three modes run without a GUI:

```sh
APP=".build/Build/Products/Debug/M8U eX Control Centre.app/Contents/MacOS/M8U eX Control Centre"

"$APP" --selftest     # run the engine test suite, non-zero exit on failure
"$APP" --probe        # print the CoreMIDI topology and exit
"$APP" --dump-ports   # as --probe, plus the port table the app builds
```

### `--selftest`

76 checks covering the MIDI byte-stream parser (running status, SysEx spanning
packets, real-time bytes interleaved mid-message, malformed data), route
filtering, transforms, multi-unit identity, rig persistence, and — most
importantly — **end-to-end routing over live CoreMIDI**: it creates a real virtual endpoint pair under a
second MIDI client, injects messages through the engine's actual receive path,
and asserts on what arrives at the far end.

Nothing in the test suite is a parallel implementation. It drives the same code
the hardware does.

### `--probe`

Run this with the interface plugged in. It reports exactly what macOS published:

```
[2] ESI M8U eX   (RECOGNISED AS M8U/M4U eX, manufacturer="ESI Audiotechnik GmbH", model="ESI M8U eX")
     entity[0] "Port 1" → socket 1
          source[0] "Port 1" uid=251115332 [offline]
          dest[0]   "Port 1" uid=1458659454 [offline]
     ...
```

## Architecture

```
Sources/M8UeXControlCentre/
  App/
    M8UeXControlCentreApp.swift   SwiftUI app; command-line mode dispatch
    AppState.swift                Selection state, routing edits, autosave
    SelfTest.swift                Headless engine test suite (--selftest)
    TopologyProbe.swift           CoreMIDI topology dump (--probe)
  Model/
    MIDIPort.swift                Logical ports and CoreMIDI endpoint snapshots
    Route.swift                   Routes, channel masks, filters, transforms
    RigStore.swift                Rig persistence; the single rig file format
  Engine/
    MIDIMessage.swift             Message model + incremental byte-stream parser
    MIDIEndpointEnumerator.swift  CoreMIDI graph walking, M8U eX recognition
    MIDIEngine.swift              Client lifecycle, routing, statistics, monitor
    MIDIPacketIO.h/.m             Objective-C shim owning the packet-list API
    MIDIPacketBridge.swift        Swift wrapper over that shim
  UI/
    DesignSystem.swift            Palette mirroring the front panel, components
    RootView.swift                Sidebar + detail + inspector
    DashboardView.swift           16 live port tiles
    PatchbayView.swift            Routing matrix
    PortInspectorView.swift       Per-port detail
    RouteInspectorView.swift      Per-route filters and transforms
    MonitorView.swift             Live MIDI log
    DiagnosticsView.swift         Health, clock, limits
    ProfileManagerView.swift      Rig library
```

### Design decisions worth knowing

**Why an Objective-C shim for MIDI I/O.** CoreMIDI's `MIDIPacketList` API is
marked deprecated in favour of `MIDIEventList` (Universal MIDI Packets). A
class-compliant MIDI 1.0 interface such as the M8U eX delivers legacy packets,
and the packet-list API remains the correct and fully supported way to talk to
one. Containing every deprecated call in `MIDIPacketIO.m` — with an explanatory
`#pragma` — lets the Swift engine use a clean interface and keeps the build free
of warnings.

**Threading.** The CoreMIDI read block runs on a high-priority thread and must
return immediately, so it only copies bytes out and hands them to a serial work
queue. All parsing, routing and statistics happen there. `@Published` state is
only mutated on the main queue, at about 20 Hz, so a busy interface cannot swamp
the UI thread.

**Running status is stateful by design.** A data byte with no status byte
legitimately continues the previous message. The parser reports genuinely
unframed data as an anomaly rather than guessing, and the monitor shows it.

**Port identity in rigs.** Routes persist `MIDIPort.ID` (`.m8u(unit:index:)`)
rather than volatile CoreMIDI endpoint references, so a rig survives reboots,
replugs and USB port changes.

## Verified against the real device

`--probe` run against the hardware confirmed the assumptions the discovery code
is built on:

- Device name `ESI M8U eX`, manufacturer `ESI Audiotechnik GmbH`
- Exactly **16 entities named "Port 1" … "Port 16"**
- Each entity exposes one source and one destination
- Endpoints report as offline when the unit is not connected

### Confirmed against the M4U eX

Both interfaces tested together on one Mac:

```
Units found:            2
Sockets found:          24
Sockets online:         24

UNIT  ESI M4U eX   deviceUID=-1905389194   sockets=8
UNIT  ESI M8U eX   deviceUID=-1091126212   sockets=16
```

The M4U eX reports as `ESI M4U eX` and exposes exactly **8 entities named
`Port 1` … `Port 8`** — the same architecture as the M8U eX with fewer sockets,
as documented. Both units run concurrently, and their socket identities never
collide despite both numbering from 1.

## Licence

Provided as-is for personal and professional use with ESI M8U eX hardware.
