#!/usr/bin/env python3
"""Generates mac/ChessLens/Resources/Assets.xcassets from web/index.html:
 - piece image sets (cburnett SVG symbols, extracted verbatim)
 - colour sets for the design tokens (light + dark)
Re-run after changing the web design tokens or piece art."""
import json, os, re, sys

root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
html = open(os.path.join(root, "web", "index.html"), encoding="utf-8").read()
out = os.path.join(root, "mac", "ChessLens", "Resources", "Assets.xcassets")
os.makedirs(out, exist_ok=True)
json.dump({"info": {"version": 1, "author": "xcode"}}, open(os.path.join(out, "Contents.json"), "w"), indent=2)

# ---- pieces
for m in re.finditer(r'<symbol id="p-([wb][kqbnrp])" viewBox="([^"]+)">(.*?)</symbol>', html, re.S):
    name, vb, body = m.groups()
    d = os.path.join(out, "Pieces", f"{name}.imageset")
    os.makedirs(d, exist_ok=True)
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="40" height="40">{body}</svg>\n'
    open(os.path.join(d, f"{name}.svg"), "w").write(svg)
    json.dump({"images": [{"filename": f"{name}.svg", "idiom": "universal"}],
               "info": {"version": 1, "author": "xcode"},
               "properties": {"preserves-vector-representation": True}},
              open(os.path.join(d, "Contents.json"), "w"), indent=2)
os.makedirs(os.path.join(out, "Pieces"), exist_ok=True)
json.dump({"info": {"version": 1, "author": "xcode"}, "properties": {"provides-namespace": False}},
          open(os.path.join(out, "Pieces", "Contents.json"), "w"), indent=2)

# ---- colours
def parse_block(text):
    return dict(re.findall(r'--([a-z0-9-]+):\s*([^;]+);', text))

light = parse_block(re.search(r':root\{(.*?)\n\}', html, re.S).group(1))
dark = parse_block(re.search(r':root\[data-theme="dark"\]\{(.*?)\n\}', html, re.S).group(1))
merged_dark = {**light, **dark}

def rgba(v):
    v = v.strip()
    if v.startswith("#"):
        h = v[1:]
        if len(h) == 3: h = "".join(c * 2 for c in h)
        return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)] + [1.0]
    m = re.match(r'rgba?\(([^)]+)\)', v)
    parts = [p.strip() for p in m.group(1).split(",")]
    r, g, b = (int(float(p)) / 255 for p in parts[:3])
    a = float(parts[3]) if len(parts) > 3 else 1.0
    return [r, g, b, a]

def comp(v):
    r, g, b, a = rgba(v)
    return {"color-space": "srgb", "components": {"red": f"{r:.4f}", "green": f"{g:.4f}", "blue": f"{b:.4f}", "alpha": f"{a:.4f}"}}

names = ["bg", "surface", "surface-2", "ink", "ink-2", "ink-3", "line", "line-2", "accent", "accent-ink", "accent-soft",
         "focus", "sq-l", "sq-d", "hl-last", "hl-sel", "dot", "check", "arrow", "bar-w", "bar-b", "bar-line",
         "good", "inacc", "mist", "blund", "scrim"]

def camel(n):
    p = n.split("-")
    return p[0] + "".join(x.capitalize() for x in p[1:])

cdir = os.path.join(out, "Colors")
os.makedirs(cdir, exist_ok=True)
json.dump({"info": {"version": 1, "author": "xcode"}, "properties": {"provides-namespace": False}},
          open(os.path.join(cdir, "Contents.json"), "w"), indent=2)
for n in names:
    d = os.path.join(cdir, f"{camel(n)}.colorset")
    os.makedirs(d, exist_ok=True)
    json.dump({"colors": [
        {"idiom": "universal", "color": comp(light[n])},
        {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": comp(merged_dark[n])},
    ], "info": {"version": 1, "author": "xcode"}}, open(os.path.join(d, "Contents.json"), "w"), indent=2)

# app accent colour (used by SwiftUI controls)
d = os.path.join(out, "AccentColor.colorset")
os.makedirs(d, exist_ok=True)
json.dump({"colors": [
    {"idiom": "universal", "color": comp(light["accent"])},
    {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": comp(merged_dark["accent"])},
], "info": {"version": 1, "author": "xcode"}}, open(os.path.join(d, "Contents.json"), "w"), indent=2)
print("wrote", out)
