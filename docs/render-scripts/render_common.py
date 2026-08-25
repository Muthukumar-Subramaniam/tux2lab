#!/usr/bin/env python3
"""Shared terminal-to-PNG renderer for tux2lab outputs."""
import math
import os
from PIL import Image, ImageDraw, ImageFont

_HERE = os.path.dirname(os.path.abspath(__file__))
FONT_REG = os.path.join(_HERE, "fonts", "SourceCodePro-Regular.ttf")
FONT_BOLD = os.path.join(_HERE, "fonts", "SourceCodePro-Bold.ttf")
OUT_DIR = os.path.normpath(os.path.join(_HERE, "..", "images"))
SIZE = 22
reg = ImageFont.truetype(FONT_REG, SIZE)
bold = ImageFont.truetype(FONT_BOLD, SIZE)

RED=(205,0,0); GREEN=(0,205,0); YELLOW=(205,205,0); MAGENTA=(205,0,205)
CYAN=(0,205,205); WHITE=(229,229,229); DEFAULT=(200,200,200); BG=(12,12,12)
P_RED=(215,0,0); P_GOLD=(255,215,0); P_CYAN=(95,255,255); P_GREY=(208,208,208)

AST = "\x00AST"  # sentinel: composite circled-asterisk glyph

def seg(t, c, b=False): return (t, c, b)

def prompt(cwd, cmd):
    s=[seg("[",P_RED),seg("JARVIS",P_GOLD,True),seg("]",P_RED),
       seg("(",P_RED),seg(AST,P_CYAN,True),seg(")",P_RED),
       seg("[",P_RED),seg(cwd,P_GREY),seg("]",P_RED),
       seg("▶",P_GOLD,True),seg(" ",DEFAULT)]
    if cmd: s.append(seg(cmd,DEFAULT))
    return s

def task(text,tag,tagcolor): return [seg("[TASK] "+text,CYAN),seg(" "+tag,tagcolor)]
def whole(text,color,b=False): return [seg(text,color,b)]
def kv(label,value): return [seg(label,CYAN),seg(" "+value,DEFAULT)]
def passline(text): return [seg("  [PASS]",GREEN),seg(" "+text,DEFAULT)]
def portline(name, ok4=True, ok6=True):
    # Matches health.sh: "[ ] name  IPv4 ✓  IPv6 ✓" — IPv6 label falls back to
    # default color because the IPv4 indicator resets. Name padded to 11.
    sym4 = seg("✓", GREEN) if ok4 else seg("✗", RED)
    sym6 = seg("✓", GREEN) if ok6 else seg("✗", RED)
    overall = seg("✓", GREEN) if (ok4 and ok6) else seg("✗", RED)
    return [seg("[ ", CYAN), overall, seg(" ] ", CYAN),
            seg(name.ljust(11), CYAN), seg("  IPv4 ", CYAN), sym4,
            seg("  IPv6 ", DEFAULT), sym6]

def _paste_circled_ast(img, x, y, char_w, ascent, color):
    # Supersample for smooth anti-aliased circle + asterisk
    S = 4
    cell_w = int(round(char_w))
    cell_h = int(round(ascent))
    tw, th = cell_w*S, cell_h*S
    tile = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    cx, cy = tw/2.0, th*0.55
    r = char_w*0.42*S
    lw = max(2, int(round(S*0.9)))
    td.ellipse((cx-r, cy-r, cx+r, cy+r), outline=color, width=lw)
    ra = r*0.58
    for deg in (90, 30, -30):  # three lines -> six-point asterisk
        a = math.radians(deg)
        dx, dy = ra*math.cos(a), ra*math.sin(a)
        td.line((cx-dx, cy-dy, cx+dx, cy+dy), fill=color, width=lw)
    tile = tile.resize((cell_w, cell_h), Image.LANCZOS)
    img.paste(tile, (int(round(x)), int(round(y))), tile)

def render(lines, outname):
    char_w = reg.getlength("M")
    ascent, descent = reg.getmetrics()
    line_h = ascent + descent + 6
    pad = 24
    max_chars = max(sum(len(t) for t,_,_ in ln) for ln in lines)
    W = int(char_w*max_chars) + pad*2
    H = line_h*len(lines) + pad*2
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    y = pad
    for ln in lines:
        x = pad
        for text, color, b in ln:
            if text == AST:
                _paste_circled_ast(img, x, y, char_w, ascent, color)
                x += char_w
            else:
                d.text((x, y), text, font=(bold if b else reg), fill=color)
                x += char_w*len(text)
        y += line_h
    os.makedirs(OUT_DIR, exist_ok=True)
    outpath = outname if os.path.isabs(outname) else os.path.join(OUT_DIR, outname)
    img.save(outpath)
    print("Saved", outpath, W, "x", H)
