# Hardware investigation — can custom routing be stored in the interface?

**Short answer: no.** This document records what was attempted, what was measured, and
why every route closed. It exists so the work isn't repeated.

The goal was simple to state: replace the M4U eX / M8U eX's fixed standalone modes
(pass-through, thru, merge) with a **custom routing configuration stored in the
hardware**, so the rig runs without a computer and without a window open.

## Verdict

The routing logic is not reachable, readable, or writable by any means available to
an owner of the device. Five independent lines of evidence agree.

| Evidence | Finding |
|---|---|
| USB descriptors (measured) | The M4U eX exposes **only** Audio Control and MIDI Streaming interfaces. **No vendor-specific interface, no DFU interface.** |
| SysEx probe (measured, both units) | Identity Requests and arbitrary SysEx are **only echoed** by a cable loop, never answered. No SysEx implementation. |
| ESI Windows driver (inspected) | Pure port virtualisation. No configuration code, no SysEx. Changelog mentions only a position-pointer fix. |
| TUSB9261 datasheet (TI) | A USB 3.0 ↔ **SATA bridge** with an ARM Cortex-M3. Its ROM loads firmware from SPI flash. The "Firmware Update Via USB" feature is TI's SATA tooling, not an ESI feature. |
| M4U eX / M8U eX user guides | **Firmware is never mentioned.** The documented configuration surface is a MODE button and three DIP switches. |

## Component inventory (read from teardown photographs)

| Ref | Marking | Function |
|---|---|---|
| `U8` | **TUSB9261** | TI USB 3.0↔SATA bridge, 64-QFP, ARM Cortex-M3 inside. **The only programmable core on the board.** |
| `U51` | **VL813-Q7** | VIA Labs 4-port USB 3.0 hub — drives the three USB-A ports |
| — | **AP2156** | USB power distribution switch (8-pin) |
| `U43 U40 U33 U27 U32 U31 U36 U38 U42` | **ULN2003A** | Darlington arrays — front-panel LED drivers |
| `U10 U21 U14 U24 U23 U19 U29` | **74HC4050D** | hex level shifters |
| `U16` | **74LV4066D** | quad analog switch |
| — | **74HC138** | 3-to-8 decoder — port addressing |
| `U7` | **AMS1117-3.3** | LDO regulator |
| `Y2`, `L9`, `D8..D39` | — | crystal, inductors, TVS protection |

Boards: `M4U_eX.01.08` (main), `M4U_eX.02.04` (LED), `M4U_eX.03.xx` (front panel).

**No SPI flash and no EEPROM was found on the board.** The one 8-pin chip that could
have been memory is the AP2156 power switch. Note this conflicts with the TUSB9261
datasheet, which says the part loads firmware from an attached SPI flash — so either
the flash is present but obscured in the photographs, or ESI used a masked/ROM variant
of the part. See "Open question" below.

See `M4U_eX_block_schematic.png` for the functional block diagram. Every block in it is
tagged `[M]` measured or `[I]` inferred; no pin-level netlist was derived, because the
signal traces run on inner PCB layers that photographs cannot reveal.

## Why the firmware cannot simply be dumped and patched

Even taking the most optimistic reading:

1. **The firmware is not in a socketed chip.** Nothing on the board can be clipped onto
   with a programmer.
2. **TI do not publish the TUSB9261 firmware source**, and their update tooling writes
   *SATA bridge* firmware — which would make the device enumerate as a mass-storage
   bridge, not a MIDI interface. That is worse than the starting point.
3. **ESI publish no firmware** for either unit, so there is no image to restore from.
   Any destructive experiment risks an unrecoverable brick.

## Open question

The TUSB9261 datasheet states the ROM loads a firmware image from an **attached SPI
flash**. No such flash chip was identified on the board across 19 photographs. Two
possible explanations:

- A small SPI flash exists but was not captured clearly; or
- ESI ordered a masked/ROM variant of the part, which would be consistent with the
  absence of any firmware-update path and the total silence about firmware in the manual.

Resolving this would require physically locating an 8-pin `25`-series chip near `U8`
(pins 17, 18, 20, 21 are SPI), or continuity-tracing from those pins.

## What actually works instead

1. **This app as the router** (what it is built for). Enable *Keep routing when the
   window is closed* and *Start automatically when I log in* in Preferences, and the
   routing survives closing the window and rebooting.
2. **A hardware MIDI router.** A device such as the Blokas Midihub performs arbitrary
   routing in hardware, runs standalone, and is designed to be programmed. That is the
   custom-routing-in-hardware outcome this investigation could not reach on the ESI units.

## Methods used

- `--probe` — CoreMIDI topology dump
- `--watch` — live USB/CoreMIDI attach detection
- `--interrogate` — read-only SysEx Identity Request, with loopback-echo detection
- `--verify-route` / `--verify-out` — end-to-end routing proof against real hardware
- `tools/m4u_specs.sh` — full host-side report for a connected interface
- `tools/m4usysex.swift` — raw-byte SysEx probe with correct multi-packet reassembly

One methodological note worth keeping: an early SysEx probe appeared to show the device
replying with a bare `F7`. That was an artefact — the reply was the device's own echo of
our request, split across two CoreMIDI packets, and the parser surfaced only the
terminator. Raw byte capture with proper reassembly is what settled it. Treat any
"the device replied" conclusion as unproven until the bytes have been reassembled.
