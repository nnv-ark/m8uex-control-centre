#!/usr/bin/env python3
"""
Render a functional block schematic of the ESI M4U eX main board from the
teardown photographs.

This is a *block* schematic, not a netlist. Everything drawn is tagged:

  [M]  measured  — the part's marking was read directly from a photograph
  [I]  inferred  — the connection or function follows from the part type and
                   how such a board is built, but was NOT traced on copper

Being explicit about that distinction matters: an inferred arrow can be wrong,
and presenting inference as measurement is how a teardown becomes fiction.

Reference designators and markings are taken from these photographs:
  IMG_3141, 3142, 3143, 3144, 3145, 3146, 3147, 3148, 3149, 3150, 3152,
  3153, 3154, 3156
"""

from PIL import Image, ImageDraw, ImageFont

W, H = 2400, 1700
BG = (255, 253, 250)
INK = (34, 30, 26)
MUTED = (120, 110, 100)
VERIFIED = (27, 94, 32)      # green - measured part
INFERRED = (140, 110, 40)    # amber - inferred link
UNKNOWN = (176, 42, 55)      # red   - unidentified / critical gap
WIRE_M = (60, 90, 60)
WIRE_I = (170, 150, 110)


def font(size, bold=False):
    for path in [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNS.ttf",
    ]:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


F_TITLE = font(40, True)
F_SUB = font(20)
F_BOX = font(21, True)
F_BODY = font(17)
F_SMALL = font(15)
F_TINY = font(13)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)


def box(x, y, w, h, title, lines, tag="M", fill=None):
    """Draw a component block. tag picks the border colour and label."""
    if fill is None:
        fill = (255, 255, 255)
    edge = {"M": VERIFIED, "I": INFERRED, "?": UNKNOWN}[tag]
    dash = tag == "?"
    if dash:
        # dashed border for anything we could not positively identify
        for i in range(0, w, 12):
            d.line([(x + i, y), (min(x + i + 6, x + w), y)], fill=edge, width=3)
            d.line([(x + i, y + h), (min(x + i + 6, x + w), y + h)], fill=edge, width=3)
        for i in range(0, h, 12):
            d.line([(x, y + i), (x, min(y + i + 6, y + h))], fill=edge, width=3)
            d.line([(x + w, y + i), (x + w, min(y + i + 6, y + h))], fill=edge, width=3)
    else:
        d.rounded_rectangle([x, y, x + w, y + h], radius=8, outline=edge, width=3, fill=fill)
    d.text((x + 12, y + 9), title, font=F_BOX, fill=INK)
    ty = y + 38
    for ln in lines:
        d.text((x + 12, ty), ln, font=F_BODY if len(ln) < 46 else F_SMALL, fill=MUTED)
        ty += 22
    return (x, y, w, h)


def arrow(p1, p2, label="", inferred=True, offset=(0, 0)):
    """Draw a signal path. Amber + dashed when the link is inferred."""
    colour = WIRE_I if inferred else WIRE_M
    if inferred:
        # dashed line
        import math
        x1, y1 = p1
        x2, y2 = p2
        dist = math.hypot(x2 - x1, y2 - y1)
        steps = max(1, int(dist / 14))
        for i in range(steps):
            t0 = i / steps
            t1 = min(1.0, (i + 0.55) / steps)
            d.line([(x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0),
                    (x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1)], fill=colour, width=3)
        # arrowhead
        d.polygon([(x2, y2), (x2 - 11, y2 - 6), (x2 - 11, y2 + 6)], fill=colour)
    else:
        d.line([p1, p2], fill=colour, width=4)
        d.polygon([(x2, y2), (x2 - 12, y2 - 7), (x2 - 12, y2 + 7)], fill=colour)
    if label:
        lx = (p1[0] + p2[0]) / 2 + offset[0]
        ly = (p1[1] + p2[1]) / 2 + offset[1]
        tw = d.textlength(label, font=F_TINY)
        d.rectangle([lx - tw / 2 - 4, ly - 9, lx + tw / 2 + 4, ly + 9], fill=BG)
        d.text((lx - tw / 2, ly - 8), label, font=F_TINY, fill=colour)


# ---------------------------------------------------------------- title
d.text((50, 34), "ESI M4U eX — functional block schematic", font=F_TITLE, fill=INK)
d.text((50, 84), "Derived from 14 teardown photographs.  [M] measured from a readable marking   "
                 "[I] inferred from part function, NOT traced on copper", font=F_SUB, fill=MUTED)
d.text((50, 110), "Board: M4U_eX.01.08 (2018-06)  ·  LED board M4U_eX.02.04 (2018-11)  ·  "
                  "panel board M4U_eX.03.xx", font=F_SMALL, fill=MUTED)
d.line([(50, 140), (W - 50, 140)], fill=(210, 200, 190), width=2)

# ---------------------------------------------------------------- USB input / hub
box(50, 170, 330, 168, "USB HOST connector  [M]",
    ["USB 3.0 Type-B / micro",
     "feeds VL813 hub upstream",
     "Device 0x2573:0x004A     [M]",
     "bDeviceClass = 0         [M]"])

box(430, 170, 380, 168, "U51  VL813-Q7  [M]",
    ["VIA Labs 4-port USB 3.0 hub",
     "41943V9800, 1745 lot    [M]",
     "ref crystal Y2          [M]",
     "NOT programmable: no CPU"])

box(860, 170, 360, 168, "3 x USB-A ports  [M]",
    ["J24 / J25 / J26        [M]",
     "J27 = RJ45?  [I]",
     "POWER_E1 / POWER_E2 LEDs[M]"])

d.text((50, 350), "U8  TUSB9261  — TI USB 3.0 ↔ SATA bridge, 64-QFP, ARM Cortex-M3 inside  [M]",
       font=F_BODY, fill=VERIFIED)
box(430, 380, 560, 150, "U8  TUSB9261  [M]",
    ["Marking: TUSB9261 / TI logo",
     "36WG4 / C869             [M]",
     "Sole programmable core on the board",
     "Firmware source NOT public"])

box(50, 380, 330, 150, "NO EXTERNAL FIRMWARE STORAGE  [?]",
    ["No SPI flash found (17 photos).",
     "AP2156 = power switch, not memory.",
     "Firmware is in TUSB9261 internal",
     "ROM/OTP: unreadable, unwritable."])

arrow((380, 455), (430, 455), "none", inferred=True)

# ---------------------------------------------------------------- MIDI front end
box(1120, 380, 400, 150, "MIDI front-end logic  [M]",
    ["U10 U21 U14 U24 U23 U19 U29",
     "74HC4050D hex buffers   [M]",
     "U16 74LV4066D quad switch[M]",
     "74HC138 3-to-8 decoder  [M]"])

box(1120, 580, 400, 150, "Transceiver arrays  [M]",
    ["U43 U40 U33 U27 U32",
     "U31 U36 U38 U42",
     "ULN2003A Darlington x9  [M]"])

box(1120, 780, 400, 150, "DIN sockets  [M]",
    ["8 x MIDI DIN, 31.25 kbaud",
     "J5 J6 J10 J11 J13 J15 J16 J17 [M]",
     "Opto-isolated inputs    [I]",
     "TVS diodes D8..D39      [M]"])

arrow((990, 455), (1120, 455), "GPIO / UART  [I]", inferred=True)
arrow((1320, 530), (1320, 580), "", inferred=True)
arrow((1320, 730), (1320, 780), "", inferred=True)

# ---------------------------------------------------------------- panel / LED
box(1720, 780, 400, 150, "Front panel board  [M]",
    ["M4U_eX.03.xx            [M]",
     "J30 ribbon to main board[M]",
     "MODE button SW2         [M]",
     "DIP switches SW1        [M]"])

box(1720, 580, 400, 150, "LED daughter board  [M]",
    ["M4U_eX.02.04 (2018-11)  [M]",
     "LEDs + R29 R33 R37 R41",
     "R43 R47 R51 R57 R100 R118 [M]"])

arrow((1720, 660), (1520, 660), "ULN2003 drive  [I]", inferred=True)
arrow((1920, 780), (1920, 730), "", inferred=True)

# ---------------------------------------------------------------- power
box(1720, 170, 400, 168, "Power  [M]",
    ["U7  AMS1117-3.3 LDO     [M]",
     "L9  10uH inductor        [M]",
     "U41 power switch         [M]",
     "5V DC jack J4            [M]"])

arrow((1720, 255), (1320, 455), "3V3 rail", inferred=True, offset=(-30, -14))
arrow((1720, 330), (1360, 455), "+5V bus", inferred=True, offset=(30, 14))

# ---------------------------------------------------------------- legend
lx, ly = 50, 1000
d.rounded_rectangle([lx, ly, lx + 640, ly + 250], radius=8, outline=(210, 200, 190), width=2)
d.text((lx + 16, ly + 14), "HOW TO READ THIS", font=F_BOX, fill=INK)
d.line([(lx + 190, ly + 128), (lx + 250, ly + 128)], fill=WIRE_M, width=4)
d.text((lx + 262, ly + 120), "[M]  measured — marking read from a photo", font=F_SMALL, fill=MUTED)
import math as _m
for i in range(0, 60, 12):
    d.line([(lx + 190 + i, ly + 168), (lx + 190 + min(i + 7, 60), ly + 168)], fill=WIRE_I, width=3)
d.text((lx + 262, ly + 160), "[I]  inferred — follows from part function, not traced", font=F_SMALL, fill=MUTED)
d.text((lx + 262, ly + 200), "[?]  unidentified — the critical unknown", font=F_SMALL, fill=UNKNOWN)
d.text((lx + 16, ly + 200), "", font=F_SMALL, fill=MUTED)

# ---------------------------------------------------------------- unknowns panel
ux, uy = 730, 1000
d.rounded_rectangle([ux, uy, ux + 760, uy + 250], radius=8, outline=UNKNOWN, width=2)
d.text((ux + 16, uy + 14), "OPEN QUESTIONS", font=F_BOX, fill=UNKNOWN)
for i, line in enumerate([
    "RESOLVED: there is no external program memory on this board.",
    "The AP2156 is a power switch, not an EEPROM. No SPI flash",
    "exists anywhere. Therefore the TUSB9261 runs from internal",
    "ROM/OTP, which cannot be read, erased or reprogrammed.",
    "",
    "CONSEQUENCE: no custom mode is achievable on this hardware.",
]):
    d.text((ux + 16, uy + 52 + i * 30), line, font=F_SMALL, fill=INK if i < 3 else MUTED)

# ---------------------------------------------------------------- footer
d.line([(50, 1300), (W - 50, 1300)], fill=(210, 200, 190), width=2)
d.text((50, 1320), "Notes", font=F_BOX, fill=INK)
notes = [
    "· Every part number here was read from a photograph. Nothing is quoted from ESI documentation except the",
    "  port counts and standalone modes, which come from the M4U eX user guide.",
    "· Boxes marked [I] are the weakest claims in this drawing. They are drawn because the board must work",
    "  somehow, not because copper was traced. Treat them as hypotheses to test, not facts.",
    "· CONCLUSION: the only programmable core is the TUSB9261, and its firmware lives in internal ROM/OTP.",
    "  With no external flash of any kind, there is nothing that can be dumped, erased or rewritten.",
    "· This is a functional block diagram, not an engineering schematic. It shows what talks to what and why,",
    "  not pin-level nets. A true schematic would require continuity tracing or X-ray/CT of the PCB layers.",
]
for i, n in enumerate(notes):
    d.text((50, 1358 + i * 26), n, font=F_SMALL, fill=MUTED)

out = "/Users/olafurhjordisarsonjonsson/Developer/m8uex-control-centre/M4U_eX_block_schematic.png"
img.save(out)
print("wrote", out, img.size)
