"""Builds the Odyssey Finance app icon from exact geometry.

    python3 design/app-icon/make_icon.py

Writes the SVG sources next to this script and the three 1024px PNGs (default, dark,
tinted) into App/Assets.xcassets/AppIcon.appiconset. Needs rsvg-convert (librsvg) and Pillow.
"""
import math
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path

from PIL import Image

S = 1024
C = S / 2
HERE = Path(__file__).resolve().parent
ICONSET = HERE.parent.parent / "App/Assets.xcassets/AppIcon.appiconset"
LIGHT_DIR = (-0.62, -0.78)


@dataclass(frozen=True)
class Style:
    bg_top: str = "#0E4A45"
    bg_bottom: str = "#03191A"
    glow: str = "#12A393"
    glow_alpha: float = 0.30
    ring_stops: tuple = ("#5ED8C9", "#1E9E90", "#0A635B")
    north_lit: tuple = ("#FFFFFF", "#B4FAF1")
    north_shade: tuple = ("#62E8D8", "#1CAE9E")
    ray_lit: tuple = ("#3CC6B6", "#2BAE9F")
    ray_shade: tuple = ("#0F877B", "#0A665E")
    minor_lit: str = "#0F6A62"
    minor_shade: str = "#0B4F49"
    hub: str = "#04231F"
    dot: str = "#F4FFFD"


DEFAULT = Style()
DARK = replace(
    DEFAULT, bg_top="#0C1716", bg_bottom="#020707", glow="#0E7E73", glow_alpha=0.26,
    ring_stops=("#5ED8C9", "#1E9E90", "#0B5F58"), hub="#020D0C",
)
# iOS keeps only the luminance of the tinted icon and applies the user's tint over black.
TINTED = replace(
    DEFAULT, bg_top="#000000", bg_bottom="#000000", glow_alpha=0.0,
    ring_stops=("#D9D9D9", "#9E9E9E", "#6B6B6B"),
    north_lit=("#FFFFFF", "#F4F4F4"), north_shade=("#CFCFCF", "#B0B0B0"),
    ray_lit=("#9C9C9C", "#8A8A8A"), ray_shade=("#5E5E5E", "#4C4C4C"),
    minor_lit="#363636", minor_shade="#272727", hub="#000000", dot="#FFFFFF",
)

# Geometry, in px on the 1024 canvas.
RING_R, RING_W = 294, 44
NORTH, RAY, INNER = 420, 252, 78
MINOR, MINOR_INNER = 156, 50
KNOCK = 24          # clearance cut into the ring around the north ray
HUB_R, DOT_R = 31, 15
SHIFT = 24          # the long north ray makes the mark top-heavy; drop it to the optical centre


def pol(r, deg):
    a = math.radians(deg - 90)
    return (C + r * math.cos(a), C + r * math.sin(a))


def pts(*ps):
    return " ".join(f"{x:.2f},{y:.2f}" for x, y in ps)


def lit(tip_deg, side):
    nx, ny = pol(1, tip_deg + side * 90)
    return (nx - C) * LIGHT_DIR[0] + (ny - C) * LIGHT_DIR[1] > 0


def ray(tip_deg, length, inner, lit_fill, shade_fill, gid):
    """A compass ray split along its spine into a lit and a shaded facet."""
    tip = pol(length, tip_deg)
    defs, body = [], []
    for side in (-1, 1):
        base = pol(inner, tip_deg + side * 45)
        fill = lit_fill if lit(tip_deg, side) else shade_fill
        if not isinstance(fill, str):
            g = f"{gid}{side + 1}"
            x1, y1 = pol(inner * 0.6, tip_deg)
            defs.append(
                f'<linearGradient id="{g}" gradientUnits="userSpaceOnUse" x1="{x1:.1f}" y1="{y1:.1f}" '
                f'x2="{tip[0]:.1f}" y2="{tip[1]:.1f}"><stop offset="0" stop-color="{fill[1]}"/>'
                f'<stop offset="1" stop-color="{fill[0]}"/></linearGradient>'
            )
            fill = f"url(#{g})"
        body.append(f'<polygon points="{pts((C, C), base, tip)}" fill="{fill}"/>')
    return defs, body


def svg(st: Style):
    tip, left, right = pol(NORTH, 0), pol(INNER, -45), pol(INNER, 45)
    defs = [
        f'<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="{st.bg_top}"/>'
        f'<stop offset="1" stop-color="{st.bg_bottom}"/></linearGradient>',
        f'<radialGradient id="glow" cx="{C}" cy="{C - 40}" r="560" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{st.glow}" stop-opacity="{st.glow_alpha}"/>'
        f'<stop offset="1" stop-color="{st.glow}" stop-opacity="0"/></radialGradient>',
        f'<linearGradient id="ring" x1="0.12" y1="0.05" x2="0.88" y2="0.95">'
        + "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in zip((0, 0.5, 1), st.ring_stops))
        + "</linearGradient>",
        f'<mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="{S}" height="{S}">'
        f'<rect width="{S}" height="{S}" fill="#fff"/><polygon points="{pts((C, C), left, tip, right)}" '
        f'fill="#000" stroke="#000" stroke-width="{KNOCK * 2}" stroke-linejoin="round"/></mask>',
    ]
    body = [
        f'<rect width="{S}" height="{S}" fill="url(#bg)"/>',
        f'<rect width="{S}" height="{S}" fill="url(#glow)"/>',
        f'<g transform="translate(0 {SHIFT})">',
        f'<circle cx="{C}" cy="{C}" r="{RING_R}" fill="none" stroke="url(#ring)" stroke-width="{RING_W}" '
        f'mask="url(#cut)"/>',
    ]
    rays = [(d, MINOR, MINOR_INNER, st.minor_lit, st.minor_shade) for d in (45, 135, 225, 315)]
    rays += [(d, RAY, INNER, st.ray_lit, st.ray_shade) for d in (90, 180, 270)]
    rays += [(0, NORTH, INNER, st.north_lit, st.north_shade)]
    for i, (deg, length, inner, lf, sf) in enumerate(rays):
        d, b = ray(deg, length, inner, lf, sf, f"r{i}")
        defs += d
        body += b
    body += [
        f'<circle cx="{C}" cy="{C}" r="{HUB_R}" fill="{st.hub}"/>',
        f'<circle cx="{C}" cy="{C}" r="{DOT_R}" fill="{st.dot}"/>',
        "</g>",
    ]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">'
            f"<defs>{''.join(defs)}</defs>{''.join(body)}</svg>\n")


def build(name, style, png_name):
    src = HERE / f"{name}.svg"
    src.write_text(svg(style))
    dst = ICONSET / png_name
    subprocess.run(["rsvg-convert", "-w", str(S), "-h", str(S), str(src), "-o", str(dst)], check=True)
    # App Store icons must not carry an alpha channel.
    Image.open(dst).convert("RGB").save(dst, optimize=True)
    print(dst.relative_to(HERE.parent.parent))


if __name__ == "__main__":
    build("icon", DEFAULT, "icon-1024.png")
    build("icon-dark", DARK, "icon-1024-dark.png")
    build("icon-tinted", TINTED, "icon-1024-tinted.png")
