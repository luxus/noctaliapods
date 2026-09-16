#!/usr/bin/env python3
"""Approximate layout preview for the MagicPods panel/bar.

IMPORTANT: this is NOT a live Noctalia screenshot. It runs the real plugin
scripts under `luau`, captures the *actual* ui.* render tree they emit, and
rasterizes an approximation of Noctalia's controls so the layout can be
eyeballed without a running compositor. Colors approximate a dark theme.
"""

import json
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "..", "..", "..", "magicpods")
LUAU = os.environ.get("LUAU", "/tmp/luau-dl/luau")
S = 2  # render scale

PALETTE = {
    "surface": "#1e1e2e",
    "surface_variant": "#313244",
    "on_surface": "#cdd6f4",
    "on_surface_variant": "#a6adc8",
    "primary": "#89b4fa",
    "error": "#f38ba8",
    "outline": "#6c7086",
}


def resolve_color(token, default="on_surface"):
    if not token:
        token = default
    token = str(token)
    if token.startswith("#"):
        return token
    role = token.split("/")[0]
    return PALETTE.get(role, PALETTE.get(default, "#cdd6f4"))


def font(size, bold=False):
    paths = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for p in paths:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def kind(node):
    return node.get("kind") if isinstance(node, dict) else None


def children(node):
    return node.get("children", []) if isinstance(node, dict) else []


def props(node):
    return node.get("props", {}) if isinstance(node, dict) else {}


# ---- measurement -----------------------------------------------------------

def text_w(draw, text, f):
    return draw.textlength(text, font=f)


def measure(draw, node):
    k = kind(node)
    p = props(node)
    if k == "label":
        f = font(int((p.get("fontSize", 14)) * S), p.get("fontWeight") in ("bold", "heavy"))
        return text_w(draw, str(p.get("text", "")), f) + 2 * S, (p.get("fontSize", 14) + 8) * S
    if k == "glyph":
        return 20 * S, 20 * S
    if k == "button":
        f = font(int(p.get("fontSize", 13) * S), True)
        label = str(p.get("text", ""))
        w = text_w(draw, label, f) + 22 * S if label else 30 * S
        if p.get("glyph"):
            w += 18 * S
        return w, 32 * S
    if k == "toggle":
        return 42 * S, 24 * S
    if k == "progress":
        return 160 * S, (p.get("height", 6)) * S
    if k == "separator":
        return 10 * S, 9 * S
    if k == "spacer":
        return (p.get("width", 0)) * S, 0
    if k in ("column", "scroll"):
        pad = p.get("padding", 0) * S
        gap = p.get("gap", 0) * S
        w = 0
        h = 0
        kids = [c for c in children(node) if c]
        for i, c in enumerate(kids):
            cw, ch = measure(draw, c)
            w = max(w, cw)
            h += ch
            if i < len(kids) - 1:
                h += gap
        return w + 2 * pad, h + 2 * pad
    if k == "row":
        pad = p.get("padding", 0) * S
        gap = p.get("gap", 0) * S
        w = 0
        h = 0
        kids = [c for c in children(node) if c]
        for i, c in enumerate(kids):
            cw, ch = measure(draw, c)
            w += cw
            h = max(h, ch)
            if i < len(kids) - 1:
                w += gap
        return w + 2 * pad, h + 2 * pad
    return 0, 0


# ---- drawing ---------------------------------------------------------------

def rrect(draw, box, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def draw_node(draw, node, x, y, w):
    k = kind(node)
    p = props(node)

    if k == "label":
        bold = p.get("fontWeight") in ("bold", "heavy")
        f = font(int(p.get("fontSize", 14) * S), bold)
        color = resolve_color(p.get("color"), "on_surface")
        draw.text((x, y), str(p.get("text", "")), font=f, fill=color)
        return (p.get("fontSize", 14) + 8) * S

    if k == "glyph":
        color = resolve_color(p.get("color"), "on_surface")
        size = 18 * S
        rrect(draw, [x, y, x + size, y + size], radius=5 * S, outline=color, width=2)
        return 20 * S

    if k == "button":
        variant = p.get("variant", "default")
        label = str(p.get("text", ""))
        f = font(int(p.get("fontSize", 13) * S), True)
        h = 32 * S
        tw = text_w(draw, label, f) if label else 0
        bw = (tw + 22 * S) if label else 30 * S
        if p.get("glyph"):
            bw += 18 * S
        if p.get("flexGrow"):
            bw = w
        bw = min(bw, w)
        box = [x, y, x + bw, y + h]
        if variant == "primary":
            rrect(draw, box, 8 * S, fill=PALETTE["primary"])
            tcol = PALETTE["surface"]
        elif variant == "destructive":
            rrect(draw, box, 8 * S, fill=PALETTE["error"])
            tcol = PALETTE["surface"]
        elif variant == "outline":
            rrect(draw, box, 8 * S, outline=PALETTE["primary"], width=2)
            tcol = PALETTE["primary"]
        elif variant == "ghost":
            tcol = PALETTE["on_surface_variant"]
        else:
            rrect(draw, box, 8 * S, fill=PALETTE["surface_variant"])
            tcol = PALETTE["on_surface"]
        gx = x + 10 * S
        if p.get("glyph"):
            gs = 12 * S
            rrect(draw, [gx, y + (h - gs) / 2, gx + gs, y + (h + gs) / 2], 3 * S, outline=tcol, width=2)
            gx += 16 * S
        if label:
            draw.text((gx, y + (h - (p.get("fontSize", 13) * S)) / 2 - 2 * S), label, font=f, fill=tcol)
        return h

    if k == "toggle":
        checked = bool(p.get("checked"))
        w2, h2 = 40 * S, 22 * S
        track = PALETTE["primary"] if checked else PALETTE["outline"]
        rrect(draw, [x, y, x + w2, y + h2], h2 / 2, fill=track)
        r = h2 - 6 * S
        kx = x + (w2 - r - 3 * S) if checked else x + 3 * S
        draw.ellipse([kx, y + 3 * S, kx + r, y + 3 * S + r], fill=PALETTE["surface"])
        return h2

    if k == "progress":
        h = (p.get("height", 6)) * S
        fill = resolve_color(p.get("fill"), "primary")
        rrect(draw, [x, y, x + w, y + h], h / 2, fill=PALETTE["surface_variant"])
        pr = max(0.0, min(1.0, float(p.get("progress", 0))))
        if pr > 0:
            rrect(draw, [x, y, x + max(h, w * pr), y + h], h / 2, fill=fill)
        return h

    if k == "separator":
        cy = y + 4 * S
        draw.line([x, cy, x + w, cy], fill=PALETTE["outline"], width=1)
        return 9 * S

    if k == "spacer":
        return 0

    if k in ("column", "scroll"):
        pad = p.get("padding", 0) * S
        gap = p.get("gap", 0) * S
        cy = y + pad
        kids = [c for c in children(node) if c]
        for i, c in enumerate(kids):
            ch = draw_node(draw, c, x + pad, cy, w - 2 * pad)
            cy += ch + (gap if i < len(kids) - 1 else 0)
        return cy - y + pad

    if k == "row":
        pad = p.get("padding", 0) * S
        gap = p.get("gap", 0) * S
        kids = [c for c in children(node) if c]
        sizes = [measure(draw, c) for c in kids]
        row_h = max([s[1] for s in sizes], default=0)
        justify = p.get("justify")
        if justify == "space_between" and len(kids) >= 2:
            # first child left, last child right
            draw_node(draw, kids[0], x + pad, y + pad + (row_h - sizes[0][1]) / 2, sizes[0][0])
            last_w = sizes[-1][0]
            draw_node(draw, kids[-1], x + w - pad - last_w, y + pad + (row_h - sizes[-1][1]) / 2, last_w)
        else:
            avail = w - 2 * pad
            total_nat = sum(s[0] for s in sizes) + gap * max(0, len(kids) - 1)
            flex_idx = [i for i, c in enumerate(kids) if props(c).get("flexGrow")]
            per = max(0, (avail - total_nat)) / len(flex_idx) if flex_idx else 0
            cx = x + pad
            for i, c in enumerate(kids):
                cw, chh = sizes[i]
                if i in flex_idx:
                    cw += per
                draw_node(draw, c, cx, y + pad + (row_h - chh) / 2, cw)
                cx += cw + gap
        return row_h + 2 * pad

    return 0


def render_tree(tree, width, out_path, title):
    tmp = Image.new("RGB", (width, 4000), PALETTE["surface"])
    d = ImageDraw.Draw(tmp)
    used = draw_node(d, tree, 8 * S, 8 * S, width - 16 * S)
    height = int(used + 16 * S)
    img = tmp.crop((0, 0, width, height))
    img.save(out_path)
    print(f"wrote {out_path} ({width}x{height})  [{title}]")


def main():
    combined = tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False)
    for f in ["host_stub.luau", "../../../magicpods/service.luau", "../../../magicpods/bar.luau",
              "../../../magicpods/panel.luau", "dump_trees.luau"]:
        with open(os.path.join(HERE, f)) as fh:
            combined.write(fh.read())
            combined.write("\n")
    combined.close()

    result = subprocess.run([LUAU, combined.name], capture_output=True, text=True)
    os.unlink(combined.name)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)

    trees = {}
    for line in result.stdout.splitlines():
        if line.startswith("PANEL_CONNECTED="):
            trees["panel"] = json.loads(line[len("PANEL_CONNECTED="):])
        elif line.startswith("BAR_CONNECTED="):
            trees["bar"] = json.loads(line[len("BAR_CONNECTED="):])

    out_dir = os.environ.get("OUT_DIR", "/opt/cursor/artifacts")
    os.makedirs(out_dir, exist_ok=True)

    if "panel" in trees:
        render_tree(trees["panel"], 360 * S, os.path.join(out_dir, "magicpods_panel_preview.png"), "panel (connected)")
    if "bar" in trees:
        render_tree(trees["bar"], 220 * S, os.path.join(out_dir, "magicpods_bar_preview.png"), "bar widget")


if __name__ == "__main__":
    main()
