#!/usr/bin/env python3
# Generates the Deckmux icon: a graphite device
# with a thin bezel and a recessed screen, whose two lit block cursors are its
# eyes; a faint >_ in the corner. Writes AppIcon.icon (Icon Composer,
# macOS 26): the layers and icon.json, so the system renders the glass and the
# dark, clear and tinted variants. scripts/build-app.sh compiles it with actool.
import json, os, shutil

CYAN = "#22D3EE"
# Graphite with a touch of blue, so the graphite bezel stands out from it.
BACKGROUND = ["srgb:0.20392,0.22745,0.27451,1.00000", "srgb:0.06667,0.07843,0.10588,1.00000"]

# Geometry on the 1024 canvas. The device is a touch wider than tall, like a terminal.
BX, BY, BW, BH, BR = 152, 222, 720, 588, 164      # bezel
INSET = 14                                         # thin bezel
SX, SY, SW, SH, SR = BX + INSET, BY + INSET, BW - 2 * INSET, BH - 2 * INSET, BR - INSET
EW, EH, GAP = 88, 168, 84                          # eyes: block cursors
EY = SY + SH / 2 - EH / 2 + 14                     # a little under the centre: friendlier
EYES_X = (512 - GAP / 2 - EW, 512 + GAP / 2)

def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{defs}</defs>{body}</svg>\n')

def stops(items):
    return "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in items)

def linear(id_, items, x2=0, y2=1):
    return f'<linearGradient id="{id_}" x1="0" y1="0" x2="{x2}" y2="{y2}">{stops(items)}</linearGradient>'

def radial(id_, items, cy=0.5, r=0.5):
    return f'<radialGradient id="{id_}" cx="0.5" cy="{cy}" r="{r}">{stops(items)}</radialGradient>'

def rect(x, y, w, h, r, fill, extra=""):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" {extra}/>'

SCREEN = rect(SX, SY, SW, SH, SR, "#000")
LAYERS = {
    "bezel": svg(rect(BX, BY, BW, BH, BR, "url(#b)") +
                 rect(BX + 3, BY + 3, BW - 6, BH - 6, BR - 3, "none", 'stroke="#FFFFFF" stroke-opacity="0.5" stroke-width="4"'),
                 linear("b", [(0, "#5A616E", 1), (1, "#2A2E36", 1)])),
    "screen": svg(rect(SX, SY, SW, SH, SR, "url(#s)") + rect(SX, SY, SW, SH, SR, "url(#g)"),
                  linear("s", [(0, "#1A2A40", 1), (1, "#070D18", 1)]) +
                  radial("g", [(0, CYAN, 0.26), (0.6, CYAN, 0.06), (1, CYAN, 0)], cy=0.56, r=0.55)),
    # The screen sits under the bezel: a shadow along its top and edges.
    "recess": svg(f'<clipPath id="c">{SCREEN}</clipPath><g clip-path="url(#c)">'
                  f'<rect x="{SX}" y="{SY}" width="{SW}" height="64" fill="url(#r)"/>'
                  + rect(SX, SY, SW, SH, SR, "none", 'stroke="#000" stroke-opacity="0.35" stroke-width="10"') + '</g>',
                  linear("r", [(0, "#000000", 0.5), (1, "#000000", 0)])),
    # Light the cursors cast on the screen.
    "halo": svg("".join(f'<ellipse cx="{x + EW / 2}" cy="{EY + EH / 2}" rx="{EW * 1.35}" ry="{EH * 0.9}" fill="url(#h)"/>'
                        for x in EYES_X),
                radial("h", [(0, CYAN, 0.42), (0.45, CYAN, 0.14), (1, CYAN, 0)])),
    # Inset from the rounded corner (radius SR), not from the straight edges.
    "prompt": svg(f'<g fill="none" stroke="#5FE6F7" stroke-opacity="0.5" stroke-width="13" stroke-linecap="round" stroke-linejoin="round">'
                  f'<path d="M{SX + 96} {SY + 84} L{SX + 114} {SY + 100} L{SX + 96} {SY + 116}"/>'
                  f'<path d="M{SX + 130} {SY + 116} H{SX + 160}"/></g>'),
    # Lit, not plastic: saturated cyan, a bright core and a soft top highlight.
    "eyes": svg("".join(rect(x, EY, EW, EH, EW / 2, "url(#e)") + rect(x, EY, EW, EH, EW / 2, "url(#k)") +
                        rect(x + 14, EY + 10, EW - 28, 64, 30, "url(#t)") for x in EYES_X),
                linear("e", [(0, "#8DF4FF", 1), (0.5, "#25D8F5", 1), (1, "#03A9D9", 1)]) +
                radial("k", [(0, "#FFFFFF", 0.55), (1, "#FFFFFF", 0)], cy=0.42) +
                linear("t", [(0, "#FFFFFF", 0.38), (1, "#FFFFFF", 0)])),
    # Sheen across the top-left of the glass.
    "sheen": svg(f'<clipPath id="c">{SCREEN}</clipPath>'
                 f'<path d="M{SX} {SY} H{SX + SW * 0.72} L{SX + SW * 0.30} {SY + SH * 0.62} L{SX} {SY + SH * 0.62} Z" '
                 f'fill="url(#w)" clip-path="url(#c)"/>',
                 linear("w", [(0, "#FFFFFF", 0.09), (0.7, "#FFFFFF", 0)], x2=0.55, y2=0.6)),
}

def group(names, glass=False, shadow=("neutral", 0.0), specular=False, translucency=None):
    return {"blend-mode": "normal", "lighting": "individual", "specular": specular,
            "shadow": {"kind": shadow[0], "opacity": shadow[1]},
            "translucency": {"enabled": translucency is not None, "value": translucency or 0.5},
            "layers": [{"glass": glass, "hidden": False, "image-name": f"{n}.svg", "name": n, "opacity": 1}
                       for n in names]}

# Front to back, at most four groups (actool's limit). Only the bezel is
# system glass; the eyes keep their own colour (glass washed the cyan out)
# and cast a coloured shadow.
GROUPS = [group(["eyes"], shadow=("layer-color", 0.7)),
          group(["sheen", "recess", "halo", "prompt"]),
          group(["screen"]),
          group(["bezel"], glass=True, specular=True, shadow=("neutral", 0.6), translucency=0.12)]

here = os.path.dirname(os.path.abspath(__file__))
icon = os.path.join(here, "AppIcon.icon")
shutil.rmtree(os.path.join(icon, "Assets"), ignore_errors=True)
os.makedirs(os.path.join(icon, "Assets"))
for name, content in LAYERS.items():
    with open(os.path.join(icon, "Assets", f"{name}.svg"), "w") as f:
        f.write(content)
with open(os.path.join(icon, "icon.json"), "w") as f:
    json.dump({"fill": {"linear-gradient": BACKGROUND}, "groups": GROUPS,
               "supported-platforms": {"squares": ["macOS"]}}, f, indent=2)
    f.write("\n")
