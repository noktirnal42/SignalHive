#!/usr/bin/env python3
"""Generates SignalHive's aircraft map icons.

The shapes are defined here, parametrically, as painted parts in a unit square (x right, y down, nose at the top,
-1...1 on both axes). The script writes

  * Packages/SignalHiveCore/Sources/SignalHiveCore/Aviation/AircraftIconData.swift  - the geometry the map paints
  * docs/aircraft-icons.png                                                            - a preview sheet

so the icons can be seen (and reviewed) without building the app. The preview uses the same paint order as the SwiftUI
renderer (`AircraftIconRenderer`): shadow, outline, fills by tone, glass, highlights, rotor discs, lines.

Usage: script/generate_aircraft_icons.py [--preview-only]     (the preview needs Pillow)
"""
import math
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
SWIFT_OUT = os.path.join(ROOT, "Packages/SignalHiveCore/Sources/SignalHiveCore/Aviation/AircraftIconData.swift")
PNG_OUT = os.path.join(ROOT, "docs/aircraft-icons.png")


# MARK: geometry helpers

def mirrored(chain):
    """A closed symmetric outline from its right-hand chain, listed nose to tail (first and last points on x = 0)."""
    left = [(-x, y) for (x, y) in reversed(chain) if abs(x) > 1e-9]
    return list(chain) + left


def both_sides(poly):
    """A right-hand polygon and its mirror image (wings, tailplanes, engines): returns the two polygons."""
    return [poly, [(-x, y) for (x, y) in reversed(poly)]]


def scaled(poly, sx, sy=None, dx=0.0, dy=0.0):
    sy = sx if sy is None else sy
    return [(x * sx + dx, y * sy + dy) for (x, y) in poly]


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def circle_points(cx, cy, r, n=20):
    return [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


# Parts are (paint, shape). Paints: body, dark, light (fills), glass, highlight, disc (translucent), line (stroked).
# Shapes: ("poly", [(x, y), ...]), ("ellipse", cx, cy, rx, ry), ("line", x1, y1, x2, y2, width).

def poly(paint, pts):
    return (paint, ("poly", pts))


def ellipse(paint, cx, cy, rx, ry):
    return (paint, ("ellipse", cx, cy, rx, ry))


def line(x1, y1, x2, y2, width=0.035, paint="line"):
    return (paint, ("line", x1, y1, x2, y2, width))


# MARK: the icons

def airliner(fuselage=0.09, span=0.96, engines=(0.32,), stabiliser=0.42, wing_root=-0.22, wing_tip=0.25, winglets=False):
    f = fuselage
    body = mirrored([(0, -1.0), (f * 0.40, -0.97), (f * 0.72, -0.90), (f * 0.94, -0.78), (f, -0.62), (f, 0.50),
                     (f * 0.78, 0.75), (f * 0.38, 0.93), (0, 0.98)])
    wing = [(f * 0.9, wing_root), (span, wing_tip), (span, wing_tip + 0.09), (span * 0.38, 0.24), (f * 0.9, 0.24)]
    tail = [(f * 0.6, 0.66), (stabiliser, 0.90), (stabiliser, 0.97), (f * 0.6, 0.90)]
    parts = [poly("body", body)]
    parts += [poly("body", p) for p in both_sides(wing)]
    parts += [poly("dark", p) for p in both_sides(tail)]
    for ex in engines:
        # Wing leading edge y at x = ex, so the nacelle sits just ahead of it.
        t = (ex - f * 0.9) / (span - f * 0.9)
        ly = wing_root + t * (wing_tip - wing_root)
        nacelle = [(ex - 0.035, ly - 0.09), (ex, ly - 0.115), (ex + 0.035, ly - 0.09), (ex + 0.035, ly + 0.07),
                   (ex - 0.035, ly + 0.07)]
        parts += [poly("light", p) for p in both_sides(nacelle)]
    parts += [poly("glass", [(-0.035, -0.86), (0.035, -0.86), (0.05, -0.79), (-0.05, -0.79)]),
              poly("highlight", [(-f * 0.5, -0.72), (-f * 0.2, -0.72), (-f * 0.2, 0.50), (-f * 0.5, 0.50)])]
    return parts


def light_single():
    body = mirrored([(0, -0.90), (0.05, -0.88), (0.075, -0.78), (0.078, -0.30), (0.06, 0.40), (0.03, 0.85), (0, 0.90)])
    wing = [(0.07, -0.34), (0.92, -0.30), (0.92, -0.08), (0.07, -0.06)]
    tail = [(0.03, 0.66), (0.36, 0.68), (0.36, 0.84), (0.03, 0.84)]
    parts = [poly("body", body)]
    parts += [poly("body", p) for p in both_sides(wing)]
    parts += [poly("dark", p) for p in both_sides(tail)]
    parts += [poly("glass", [(-0.045, -0.58), (0.045, -0.58), (0.058, -0.36), (-0.058, -0.36)]),
              poly("highlight", [(-0.04, -0.80), (-0.018, -0.80), (-0.018, 0.5), (-0.04, 0.5)]),
              ellipse("disc", 0, -0.93, 0.34, 0.035),
              line(-0.34, -0.93, 0.34, -0.93, 0.03)]
    return parts


def bizjet():
    body = mirrored([(0, -1.0), (0.03, -0.96), (0.055, -0.86), (0.072, -0.70), (0.075, 0.30), (0.06, 0.62),
                     (0.03, 0.88), (0, 0.94)])
    wing = [(0.07, -0.12), (0.80, 0.22), (0.80, 0.31), (0.07, 0.24)]
    tail = [(0.04, 0.72), (0.34, 0.86), (0.34, 0.94), (0.04, 0.92)]
    engine = [(0.085, 0.30), (0.135, 0.28), (0.165, 0.34), (0.165, 0.66), (0.085, 0.66)]
    parts = [poly("body", body)]
    parts += [poly("body", p) for p in both_sides(wing)]
    parts += [poly("dark", p) for p in both_sides(tail)]
    parts += [poly("light", p) for p in both_sides(engine)]
    parts += [poly("glass", [(-0.03, -0.82), (0.03, -0.82), (0.042, -0.72), (-0.042, -0.72)]),
              poly("highlight", [(-0.045, -0.7), (-0.02, -0.7), (-0.02, 0.35), (-0.045, 0.35)])]
    return parts


def twin_turboprop():
    body = mirrored([(0, -0.95), (0.04, -0.93), (0.07, -0.82), (0.08, -0.55), (0.078, 0.40), (0.05, 0.75), (0, 0.92)])
    wing = [(0.07, -0.26), (0.90, -0.20), (0.90, 0.02), (0.07, 0.04)]
    tail = [(0.03, 0.68), (0.34, 0.72), (0.34, 0.88), (0.03, 0.88)]
    nacelle = [(0.30, -0.62), (0.36, -0.62), (0.37, 0.02), (0.29, 0.02)]
    parts = [poly("body", body)]
    parts += [poly("body", p) for p in both_sides(wing)]
    parts += [poly("dark", p) for p in both_sides(tail)]
    parts += [poly("light", p) for p in both_sides(nacelle)]
    parts += [ellipse("disc", 0.33, -0.66, 0.16, 0.025), ellipse("disc", -0.33, -0.66, 0.16, 0.025),
              poly("glass", [(-0.04, -0.72), (0.04, -0.72), (0.052, -0.52), (-0.052, -0.52)]),
              poly("highlight", [(-0.05, -0.85), (-0.025, -0.85), (-0.025, 0.4), (-0.05, 0.4)])]
    return parts


def fighter():
    body = mirrored([(0, -1.0), (0.03, -0.86), (0.06, -0.5), (0.075, 0.40), (0.06, 0.88), (0, 0.92)])
    wing = [(0.06, -0.30), (0.72, 0.56), (0.72, 0.68), (0.06, 0.62)]
    tail = [(0.05, 0.66), (0.30, 0.86), (0.30, 0.94), (0.05, 0.90)]
    parts = [poly("body", body)]
    parts += [poly("body", p) for p in both_sides(wing)]
    parts += [poly("dark", p) for p in both_sides(tail)]
    parts += [poly("glass", [(-0.035, -0.58), (0.035, -0.58), (0.05, -0.24), (-0.05, -0.24)]),
              poly("light", rect(-0.045, 0.78, -0.012, 0.94)), poly("light", rect(0.012, 0.78, 0.045, 0.94)),
              poly("highlight", [(-0.05, -0.6), (-0.028, -0.6), (-0.028, 0.6), (-0.05, 0.6)])]
    return parts


def helicopter():
    body = mirrored([(0, -0.58), (0.10, -0.52), (0.165, -0.32), (0.17, 0.02), (0.11, 0.24), (0.04, 0.36), (0, 0.38)])
    boom = [(-0.032, 0.22), (0.032, 0.22), (0.024, 0.86), (-0.024, 0.86)]
    fin = [(-0.10, 0.76), (0.10, 0.80), (0.10, 0.88), (-0.10, 0.86)]
    parts = [poly("body", body), poly("body", boom), poly("dark", fin),
             poly("glass", [(-0.09, -0.50), (0.09, -0.50), (0.12, -0.30), (-0.12, -0.30)]),
             poly("highlight", [(-0.09, -0.24), (-0.05, -0.24), (-0.05, 0.16), (-0.09, 0.16)]),
             ellipse("disc", 0, -0.05, 0.86, 0.86),
             line(-0.80, 0.30, 0.80, -0.40, 0.045), line(-0.62, -0.60, 0.62, 0.50, 0.045),
             ellipse("disc", 0.0, 0.84, 0.07, 0.13)]
    return parts


def glider():
    body = mirrored([(0, -0.86), (0.028, -0.80), (0.04, -0.60), (0.03, 0.62), (0.018, 0.90), (0, 0.93)])
    wing = [(0.03, -0.22), (1.0, -0.14), (1.0, -0.03), (0.03, 0.03)]
    tail = [(0.02, 0.72), (0.26, 0.78), (0.26, 0.87), (0.02, 0.87)]
    parts = [poly("body", body)]
    parts += [poly("body", p) for p in both_sides(wing)]
    parts += [poly("dark", p) for p in both_sides(tail)]
    parts += [poly("glass", [(-0.03, -0.60), (0.03, -0.60), (0.04, -0.32), (-0.04, -0.32)]),
              poly("highlight", [(-0.03, -0.3), (-0.012, -0.3), (-0.012, 0.6), (-0.03, 0.6)])]
    return parts


def balloon():
    parts = [ellipse("body", 0, -0.12, 0.62, 0.70)]
    for gx in (-0.30, 0.30):
        half = 0.70 * math.sqrt(max(0.0, 1 - (gx / 0.62) ** 2))
        parts.append(line(gx, -0.12 - half, gx, -0.12 + half, 0.03))
    parts += [line(0, -0.82, 0, 0.58, 0.03),
              ellipse("highlight", -0.24, -0.40, 0.14, 0.24),
              line(-0.16, 0.56, -0.07, 0.72, 0.022), line(0.16, 0.56, 0.07, 0.72, 0.022),
              poly("dark", rect(-0.10, 0.70, 0.10, 0.88))]
    return parts


def parachutist():
    parts = [ellipse("body", 0, -0.18, 0.78, 0.46),
             ellipse("highlight", -0.30, -0.34, 0.24, 0.12),
             line(-0.72, -0.05, 0, 0.62, 0.02), line(0.72, -0.05, 0, 0.62, 0.02), line(0, 0.28, 0, 0.62, 0.02),
             line(-0.36, 0.10, 0, 0.62, 0.02), line(0.36, 0.10, 0, 0.62, 0.02),
             ellipse("dark", 0, 0.68, 0.11, 0.11)]
    return parts


def hang_glider():
    wing = mirrored([(0, -0.90), (0.96, 0.40), (0.62, 0.50), (0, 0.16)])
    parts = [poly("body", wing), line(0, -0.92, 0, 0.28, 0.03),
             poly("highlight", [(-0.04, -0.62), (-0.01, -0.62), (-0.34, 0.24), (-0.4, 0.24)]),
             ellipse("dark", 0, 0.08, 0.075, 0.22)]
    return parts


def quadcopter():
    parts = [line(-0.6, -0.6, 0.6, 0.6, 0.05), line(0.6, -0.6, -0.6, 0.6, 0.05)]
    for cx, cy in ((-0.6, -0.6), (0.6, -0.6), (-0.6, 0.6), (0.6, 0.6)):
        parts.append(ellipse("disc", cx, cy, 0.3, 0.3))
        parts.append(ellipse("dark", cx, cy, 0.06, 0.06))
    parts += [poly("body", mirrored([(0, -0.26), (0.16, -0.2), (0.16, 0.2), (0.1, 0.26), (0, 0.26)])),
              poly("light", [(0, -0.42), (0.08, -0.28), (-0.08, -0.28)]),
              poly("glass", rect(-0.07, -0.1, 0.07, 0.06))]
    return parts


def spaceplane():
    body = mirrored([(0, -1.0), (0.06, -0.86), (0.10, -0.5), (0.11, 0.70), (0.06, 0.95), (0, 0.95)])
    wing = [(0.10, -0.05), (0.84, 0.86), (0.84, 0.96), (0.10, 0.90)]
    parts = [poly("body", body)]
    parts += [poly("body", p) for p in both_sides(wing)]
    parts += [poly("dark", rect(-0.06, 0.80, -0.02, 0.98)), poly("dark", rect(0.02, 0.80, 0.06, 0.98)),
              poly("glass", [(-0.04, -0.72), (0.04, -0.72), (0.06, -0.52), (-0.06, -0.52)])]
    return parts


def emergency_vehicle():
    body = mirrored([(0, -0.74), (0.24, -0.74), (0.31, -0.55), (0.32, 0.60), (0.27, 0.72), (0, 0.72)])
    return [poly("body", body),
            poly("glass", mirrored([(0, -0.48), (0.22, -0.48), (0.25, -0.24), (0, -0.24)])),
            poly("light", rect(-0.24, -0.06, 0.24, 0.08)),
            ellipse("dark", -0.12, 0.01, 0.06, 0.06), ellipse("dark", 0.12, 0.01, 0.06, 0.06),
            poly("highlight", [(-0.28, 0.2), (-0.2, 0.2), (-0.2, 0.62), (-0.28, 0.62)])]


def service_vehicle():
    cab = mirrored([(0, -0.82), (0.24, -0.82), (0.27, -0.66), (0.27, -0.16), (0, -0.16)])
    box = mirrored([(0, -0.10), (0.31, -0.10), (0.31, 0.82), (0, 0.82)])
    return [poly("body", cab), poly("dark", box),
            poly("glass", mirrored([(0, -0.64), (0.2, -0.64), (0.22, -0.42), (0, -0.42)])),
            poly("highlight", [(-0.27, 0.0), (-0.2, 0.0), (-0.2, 0.74), (-0.27, 0.74)])]


def _triangle(cx, cy, s):
    return [(cx, cy - 0.68 * s), (cx + 0.62 * s, cy + 0.52 * s), (cx - 0.62 * s, cy + 0.52 * s)]


def point_obstacle():
    return [poly("body", _triangle(0, 0, 1.0)), line(0, -0.22, 0, 0.14, 0.09, paint="glass"),
            ellipse("glass", 0, 0.34, 0.06, 0.06)]


def cluster_obstacle():
    parts = []
    for cx, cy in ((0, -0.42), (-0.5, 0.36), (0.5, 0.36)):
        parts.append(poly("body", _triangle(cx, cy, 0.5)))
        parts.append(ellipse("glass", cx, cy + 0.14, 0.045, 0.045))
    return parts


def line_obstacle():
    parts = [line(-0.62, -0.02, 0.62, -0.02, 0.03)]
    for cx in (-0.62, 0.62):
        parts.append(poly("body", _triangle(cx, 0.0, 0.34)))
    parts.append(line(-0.62, 0.20, 0.62, 0.20, 0.02))
    return parts


def unknown():
    return [poly("body", mirrored([(0, -0.90), (0.40, 0.66), (0, 0.34)])),
            ellipse("dark", 0, 0.02, 0.09, 0.09),
            poly("highlight", [(-0.03, -0.62), (-0.01, -0.62), (-0.2, 0.42), (-0.26, 0.42)])]


# Icon name -> parts. The names are `AircraftClass` raw values in the Swift code.
ICONS = {
    "light": light_single(),
    "small": twin_turboprop(),
    "bizjet": bizjet(),
    "large": airliner(),
    "highVortexLarge": airliner(fuselage=0.078, span=0.86, engines=(0.30,), stabiliser=0.38, wing_root=-0.16, wing_tip=0.20),
    "heavy": airliner(fuselage=0.115, span=1.0, engines=(0.27, 0.52), stabiliser=0.46, wing_root=-0.26, wing_tip=0.30),
    "highPerformance": fighter(),
    "rotorcraft": helicopter(),
    "glider": glider(),
    "lighterThanAir": balloon(),
    "parachutist": parachutist(),
    "ultralight": hang_glider(),
    "uav": quadcopter(),
    "spaceVehicle": spaceplane(),
    "surfaceEmergency": emergency_vehicle(),
    "surfaceService": service_vehicle(),
    "pointObstacle": point_obstacle(),
    "clusterObstacle": cluster_obstacle(),
    "lineObstacle": line_obstacle(),
    "unknown": unknown(),
}


# MARK: Swift output

def fmt(v):
    text = ("%.4f" % v).rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def swift_part(part):
    paint, shape = part
    kind = shape[0]
    if kind == "poly":
        flat = ", ".join(fmt(c) for p in shape[1] for c in p)
        return f'.polygon(.{paint}, [{flat}])'
    if kind == "ellipse":
        return f'.ellipse(.{paint}, {fmt(shape[1])}, {fmt(shape[2])}, {fmt(shape[3])}, {fmt(shape[4])})'
    return f'.line(.{paint}, {fmt(shape[1])}, {fmt(shape[2])}, {fmt(shape[3])}, {fmt(shape[4])}, {fmt(shape[5])})'


def write_swift():
    out = [
        "// Generated by script/generate_aircraft_icons.py - do not edit by hand; change the script and run it again.",
        "//",
        "// Aircraft map icon geometry in a unit square (x right, y down, nose at y = -1). Each part is a painted layer;",
        "// `AircraftIconRenderer` (the app) knows how to paint each `Paint`. A preview sheet is in docs/aircraft-icons.png.",
        "",
        "enum AircraftIconData {",
        "    /// Icon parts by `AircraftIconKind` raw value.",
        "    static let parts: [String: [AircraftIconPart]] = [",
    ]
    for name in ICONS:
        out.append(f'        "{name}": {name}Parts,')
    out.append("    ]")
    out.append("")
    for name, parts in ICONS.items():
        out.append(f"    private static let {name}Parts: [AircraftIconPart] = [")
        for part in parts:
            out.append(f"        {swift_part(part)},")
        out.append("    ]")
        out.append("")
    out[-1] = "}"
    with open(SWIFT_OUT, "w") as handle:
        handle.write("\n".join(out) + "\n")
    print("wrote", os.path.relpath(SWIFT_OUT, ROOT))


# MARK: preview

ALTITUDE_STOPS = [
    (0, (255, 90, 60)), (1000, (255, 130, 40)), (3000, (255, 190, 40)), (6000, (230, 235, 60)),
    (10000, (90, 225, 90)), (15000, (40, 220, 190)), (20000, (40, 175, 245)), (30000, (90, 120, 255)),
    (40000, (170, 100, 255)), (45000, (240, 100, 230)),
]


def altitude_color(feet):
    if feet <= ALTITUDE_STOPS[0][0]:
        return ALTITUDE_STOPS[0][1]
    for (a, ca), (b, cb) in zip(ALTITUDE_STOPS, ALTITUDE_STOPS[1:]):
        if feet <= b:
            t = (feet - a) / (b - a)
            return tuple(round(ca[i] + (cb[i] - ca[i]) * t) for i in range(3))
    return ALTITUDE_STOPS[-1][1]


def tone(color, factor):
    if factor <= 1:
        return tuple(round(c * factor) for c in color)
    return tuple(round(c + (255 - c) * (factor - 1)) for c in color)


def render_preview():
    from PIL import Image, ImageDraw, ImageFont

    names = list(ICONS)
    cols = 5
    rows = (len(names) + cols - 1) // cols
    cell = 190
    sheet = Image.new("RGB", (cols * cell, rows * cell + 110), (17, 22, 28))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.load_default()
    except Exception:
        font = None
    draw.text((12, 10), "SignalHive aircraft icons - large (top) at 12000 ft and small (28 px) at altitude ramp", fill=(200, 210, 220), font=font)
    # Altitude ramp strip.
    for x in range(cols * cell - 24):
        feet = 45000 * x / (cols * cell - 25)
        draw.line([(12 + x, 34), (12 + x, 52)], fill=altitude_color(feet))
    for feet in (0, 5000, 10000, 20000, 30000, 40000):
        x = 12 + (cols * cell - 25) * feet / 45000
        draw.text((x, 54), f"{feet // 1000}k", fill=(170, 180, 190), font=font)

    for index, name in enumerate(names):
        cx = (index % cols) * cell + cell // 2
        cy = 70 + (index // cols) * cell + cell // 2 - 6
        color = altitude_color(3000 + index * 1900)
        paint_icon(sheet, ICONS[name], cx, cy - 8, 68, color)
        paint_icon(sheet, ICONS[name], cx - 62, cy + 76, 14, altitude_color(500 + index * 2200))
        paint_icon(sheet, ICONS[name], cx - 14, cy + 76, 14, altitude_color(35000 - index * 1500))
        paint_icon(sheet, ICONS[name], cx + 34, cy + 76, 9, color)
        draw.text((cx - 40, cy + 92), name, fill=(190, 200, 210), font=font)
    os.makedirs(os.path.dirname(PNG_OUT), exist_ok=True)
    sheet.save(PNG_OUT)
    print("wrote", os.path.relpath(PNG_OUT, ROOT))


def paint_icon(sheet, parts, cx, cy, radius, color, supersample=4):
    """Paints one icon with the renderer's layer order onto `sheet`, centred on (cx, cy).

    Every layer is drawn on its own transparent image and alpha-composited, because PIL overwrites (rather than
    blends) translucent pixels drawn straight onto an RGBA image."""
    from PIL import Image, ImageDraw

    pad = int(radius * 1.2) + 4
    size = pad * 2
    big = size * supersample
    canvas = [Image.new("RGBA", (big, big), (0, 0, 0, 0))]
    s = radius * supersample

    def P(x, y):
        return (big / 2 + x * s, big / 2 + y * s)

    def pts(shape):
        if shape[0] == "poly":
            return [P(x, y) for x, y in shape[1]]
        return [P(shape[1] + shape[3] * math.cos(t * math.pi / 12), shape[2] + shape[4] * math.sin(t * math.pi / 12)) for t in range(24)]

    def layer(draw_fn):
        tmp = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        draw_fn(ImageDraw.Draw(tmp))
        canvas[0] = Image.alpha_composite(canvas[0], tmp)

    def stroke(d, points, width, fill, closed):
        seq = points + [points[0]] if closed else points
        d.line(seq, fill=fill, width=max(1, int(width)), joint="curve")
        for p in points:
            r = max(1, width) / 2
            d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=fill)

    fills = {"body": 1.0, "dark": 0.68, "light": 1.22}
    solid = [(paint, shape) for paint, shape in parts if paint in fills and shape[0] != "line"]
    outline_w = max(1.2, 0.055 * s) if radius > 12 else max(1.0, 0.09 * s)

    # 1. shadow
    layer(lambda d: [d.polygon([(x + 0.05 * s, y + 0.06 * s) for x, y in pts(sh)], fill=(0, 0, 0, 90)) for _, sh in solid])
    # 2. outline: every filled part is stroked before any is filled, so overlapping parts share one outline
    def outline(d):
        for _, sh in solid:
            stroke(d, pts(sh), outline_w * 2, (8, 12, 16, 235), True)
        for paint, sh in parts:
            if sh[0] == "line" and paint == "line":
                stroke(d, [P(sh[1], sh[2]), P(sh[3], sh[4])], sh[5] * s + outline_w * 1.6, (8, 12, 16, 220), False)
    layer(outline)
    # 3. fills by tone
    layer(lambda d: [d.polygon(pts(sh), fill=tone(color, fills[paint]) + (255,)) for paint, sh in solid])
    # 4. glass
    def glass(d):
        for paint, sh in parts:
            if paint == "glass":
                if sh[0] == "line":
                    stroke(d, [P(sh[1], sh[2]), P(sh[3], sh[4])], sh[5] * s, (14, 26, 40, 200), False)
                else:
                    d.polygon(pts(sh), fill=(14, 26, 40, 200))
    layer(glass)
    # 5. highlights
    layer(lambda d: [d.polygon(pts(sh), fill=(255, 255, 255, 70)) for paint, sh in parts if paint == "highlight"])
    # 6. rotor and propeller discs
    def discs(d):
        for paint, sh in parts:
            if paint == "disc":
                p = pts(sh)
                d.polygon(p, fill=color + (40,))
                stroke(d, p, max(1, 0.012 * s), color + (150,), True)
    layer(discs)
    # 7. lines (rotor blades, wires, shrouds)
    def lines(d):
        for paint, sh in parts:
            if paint == "line":
                stroke(d, [P(sh[1], sh[2]), P(sh[3], sh[4])], max(1, sh[5] * s), color + (255,), False)
    layer(lines)

    result = canvas[0].resize((size, size), Image.LANCZOS)
    sheet.paste(result, (int(cx - size / 2), int(cy - size / 2)), result)


if __name__ == "__main__":
    if "--preview-only" not in sys.argv:
        write_swift()
    render_preview()
