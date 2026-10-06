#!/bin/bash
#
# m4u_specs.sh — everything a Mac can report about a connected ESI M4U eX.
#
# Read-only. Changes no settings and writes nothing to the device.
# Runs on both Apple-silicon and Intel/T2 Macs; any section a given macOS cannot
# answer says so rather than printing a misleading zero.
#
# Usage:  bash m4u_specs.sh
#
# Output appears on screen and is saved to /tmp/m4u_specs_<timestamp>.txt
#

set -u

DEVICE='ESI M4U eX'
OUT="/tmp/m4u_specs_$(date +%Y%m%d_%H%M%S).txt"

# Mirror everything to a file so it can be pasted or shared.
exec > >(tee "$OUT") 2>&1

hr() { printf '%s\n' "--------------------------------------------------------------------"; }
h1() { echo; hr; echo " $1"; hr; }

echo "===================================================================="
echo " ESI M4U eX — host report"
echo "===================================================================="
printf " host        : %s\n" "$(hostname)"
printf " macOS       : %s %s (%s)\n" "$(sw_vers -productName)" "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
printf " architecture: %s\n" "$(uname -m)"
printf " date        : %s\n" "$(date)"
printf " saved to    : %s\n" "$OUT"

# ---------------------------------------------------------------- 1
h1 "1. IS IT CONNECTED?"

if ! ioreg -p IOUSB -w0 -l 2>/dev/null | grep -q "USB Product Name\" = \"$DEVICE"; then
  echo " NOT CONNECTED to this Mac."
  echo
  echo " ESI devices present:"
  ioreg -p IOUSB -w0 -l 2>/dev/null \
    | grep -oE '"USB Product Name" = "[^"]*(ESI|M4U|M8U)[^"]*"' | sort -u | sed 's/^/   /' \
    || echo "   (none)"
  echo
  echo " Devices macOS remembers but that are offline:"
  system_profiler SPMIDIDataType 2>/dev/null | grep -iE 'M4U|M8U' | sed 's/^/   /' \
    || echo "   (none recorded)"
  echo
  echo " Plug the interface in and run again."
  exit 0
fi
echo " Present on the USB bus."

# ---------------------------------------------------------------- 2
h1 "2. USB IDENTITY"
# Take the block that starts at the device node line and ends at the next
# device. The property list sits BELOW that node line, while some fields
# (idProduct, bcdDevice) appear above the "USB Product Name" entry — so grepping
# forward from the name misses them.
ioreg -p IOUSB -w0 -l 2>/dev/null \
  | sed -n "/+-o $DEVICE@/,/^ *[+-]-o /p" \
  | grep -E '"(USB Product Name|USB Vendor Name|idVendor|idProduct|bcdDevice|Device Speed|bNumConfigurations|bDeviceClass|bDeviceSubClass|bDeviceProtocol|kUSBSerialNumberString|LocationID|sessionID)"' \
  | sort -u | sed 's/^ */  /'

cat <<'EOF'

 What these mean:
   idVendor  9587  = 0x2573  ESI Audiotechnik GmbH
   idProduct 74    = 0x004A  M4U eX     (M8U eX is 138 = 0x008A)
   bcdDevice 256   = revision 1.00 as the device reports it
   Speed 2 = USB 2.0 (480 Mb/s) · Speed 3 = USB 3.0 (5 Gb/s)
   bDeviceClass 0  = class defined per-interface, i.e. class compliant
EOF

# ---------------------------------------------------------------- 3
h1 "3. USB INTERFACES"
echo " A class-compliant MIDI interface exposes two interfaces:"
echo "   class 1 sub 1  Audio Control"
echo "   class 1 sub 3  Audio Streaming (MIDI)"
echo " A class 255 interface would be a vendor-specific channel — the only place"
echo " a configuration protocol could hide. This device has none."
echo

IFACES=/tmp/_m4u_ifaces.$$.txt
ioreg -w0 -l -c IOUSBInterface 2>/dev/null > "$IFACES" || true

if grep -q "$DEVICE" "$IFACES"; then
  awk -v dev="$DEVICE" '
    /^ *\+-o / { keep = ($0 ~ dev) }
    keep && /bInterface(Class|SubClass|Protocol|Number)/ { print "  " $0 }
  ' "$IFACES"
else
  echo "   This macOS build does not publish per-interface records that can be"
  echo "   attributed to this device. (Intel/T2 Macs use the legacy IOUSBDevice"
  echo "   stack, which reports interfaces differently.)"
  echo
  echo "   All interface classes currently visible on this Mac, for reference:"
  ioreg -w0 -l -c IOUSBInterface 2>/dev/null \
    | grep -oE '"bInterfaceClass" = [0-9]+' | sort | uniq -c \
    | awk '{printf "     class %-4s x%s\n", $2, $1}'
  echo "     class 1 = Audio/MIDI; a vendor channel would appear as class 255"
fi
rm -f "$IFACES"

# ---------------------------------------------------------------- 4
h1 "4. MIDI ENDPOINTS"
MIDILINES=$(system_profiler SPMIDIDataType 2>/dev/null | wc -l | tr -d ' ')
if [ "${MIDILINES:-0}" -gt 0 ]; then
  system_profiler SPMIDIDataType 2>/dev/null | sed 's/^/  /'
else
  cat <<'EOF'
   This macOS build cannot report CoreMIDI from the command line.
   (system_profiler SPMIDIDataType returns nothing here.)

   To see the endpoints, open Audio MIDI Setup and click MIDI Studio:

       open -a 'Audio MIDI Setup'

   The eight M4U eX ports appear there as Port 1 … Port 8, each with a source
   and a destination.
EOF
fi

# ---------------------------------------------------------------- 5
h1 "5. USB TREE (what sits where)"
echo " The M4U eX's own 3-port hub, and anything plugged into it, appear as"
echo " children of the interface below. The hub needs the 5V supply and USB mode"
echo " (STATUS LED green); it is disabled in standalone mode."
echo
ioreg -p IOUSB -w0 2>/dev/null \
  | grep -oE '[+-]-o [^<]*' \
  | sed 's/[+-]-o /  /; s/ *<.*//; s/|/ /g'

# ---------------------------------------------------------------- 6
h1 "6. HOST MIDI INFRASTRUCTURE"
echo " USB controllers:"
ioreg -p IOUSB -w0 2>/dev/null | grep -oE 'AppleT[0-9]+USBXHCI@[0-9a-f]+' | sort -u | sed 's/^/   /'
echo
echo " CoreMIDI server process:"
launchctl list 2>/dev/null | grep -i midi | sed 's/^/   /' || echo "   (not listed by launchctl)"
echo
echo " Cached MIDI configurations (every device macOS has seen):"
ls -la ~/Library/Audio/MIDI\ Configurations/ 2>/dev/null | sed 's/^/   /' || echo "   (none)"
echo
echo " Third-party virtual MIDI drivers installed:"
ls /Library/Audio/MIDI\ Drivers/ 2>/dev/null | sed 's/^/   /' || echo "   (none)"

# ---------------------------------------------------------------- 7
h1 "7. WHAT THIS REPORT CANNOT SHOW"
cat <<'EOF'
   · Firmware. The TUSB9261 loads its firmware from an on-board SPI flash at
     power-up. Reading that requires a hardware programmer clipped to the chip;
     no macOS command can reach it.
   · A firmware-update channel. The device exposes no DFU interface and no
     vendor-specific interface, so no update path is visible to the host.
   · Port direction. Each port auto-detects input vs output from whether signal
     is flowing — decided in hardware at runtime, not a stored setting.
   · Standalone modes. Pass-through, Thru and Merge are chosen with the
     front-panel MODE button and exist only when no computer is connected.

EOF
echo "===================================================================="
echo " END OF REPORT — saved to $OUT"
echo "===================================================================="
