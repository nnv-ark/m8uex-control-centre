#!/bin/bash
#
# m4u_report.sh — describe what macOS can see about the ESI M4U eX / M8U eX.
#
# Why this exists:
#   The TUSB9261 datasheet says the chip runs boot code from internal ROM and
#   loads its real firmware from an ATTACHED SPI FLASH chip. That flash must
#   therefore exist on the board. This script collects everything macOS exposes
#   about the interface, so we can look for the firmware-update / bootloader
#   interface the datasheet says the part supports ("Firmware Update Via USB").
#
# It reads only. It changes nothing, and it talks to no device registers.
#
# Usage:  bash m4u_report.sh
#
set -u

echo "==============================================================="
echo " ESI M4U eX / M8U eX — host-side report"
echo " host: $(hostname)   macOS $(sw_vers -productVersion)   $(date)"
echo "==============================================================="
echo

echo "--- 1. Are the interfaces on the USB bus? ----------------------"
ioreg -p IOUSB -w0 2>/dev/null \
  | grep -oE '\+-o [^<@]*@' | sed 's/+-o //;s/@//' \
  | grep -iE 'esi|m4u|m8u' || echo "    (no ESI device found on USB)"
echo

echo "--- 2. Full USB descriptor for each ESI interface --------------"
for dev in "ESI M4U eX" "ESI M8U eX"; do
  if ioreg -p IOUSB -w0 -l 2>/dev/null | grep -q "\"USB Product Name\" = \"$dev\""; then
    echo "  $dev"
    ioreg -p IOUSB -w0 -l 2>/dev/null \
      | grep -A 60 "\"USB Product Name\" = \"$dev\"" \
      | grep -E '"(idVendor|idProduct|bcdDevice|Device Speed|bNumConfigurations|kUSBSerialNumberString|USB Vendor Name|bDeviceClass|bDeviceSubClass|bDeviceProtocol|LocationID|sessionID)"' \
      | sort -u | sed 's/^/      /'
    echo
    echo "    interface classes on this device:"
    ioreg -p IOUSB -w0 -l 2>/dev/null \
      | sed -n "/$dev@/,/^      +-o/p" \
      | grep -oE '"bInterfaceClass" = [0-9]+' | sort | uniq -c | sed 's/^/      /'
    echo
  fi
done

echo "--- 3. Is any DFU / bootloader / update interface present? ------"
echo "  Looking for the firmware-update interface the datasheet mentions."
echo "    A DFU device would show bInterfaceClass = 254 (Application Specific)."
echo "    A vendor bootloader would show bInterfaceClass = 255."
found=0
for cls in 254 255; do
  n=$(ioreg -p IOUSB -w0 -l 2>/dev/null | grep -c "\"bInterfaceClass\" = $cls")
  echo "    bInterfaceClass $cls occurrences: $n"
  [ "$n" -gt 0 ] && found=1
done
[ "$found" -eq 0 ] && echo "    => none. The interface presents only Audio/MIDI class, as we measured."
echo

echo "--- 4. CoreMIDI's view ----------------------------------------"
system_profiler SPMIDIDataType 2>/dev/null \
  | grep -B 2 -A 10 -iE 'M4U eX|M8U eX' | head -40 \
  || echo "    (system_profiler returned nothing for MIDI)"
echo

echo "--- 5. Installed tooling that could read a SPI flash ----------"
for t in flashrom ch341eeprom minipro avrdude; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "    $t: $(command -v "$t")"
  else
    echo "    $t: not installed"
  fi
done
echo "    (a CH341A programmer + SOIC-8 clip is a hardware step, not software)"
echo

echo "==============================================================="
echo " WHAT THIS DOES NOT DO"
echo "   No terminal command can read the firmware. The SPI flash is a"
echo "   physical chip: it needs a programmer clipped onto its pins."
echo "   This report only documents what the host can see."
echo "==============================================================="
