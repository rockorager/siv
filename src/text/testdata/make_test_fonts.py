#!/usr/bin/env python3
"""Generates the SivTest fonts for the font family tests (D13).

Blocky glyphs for space, H, I, O, and n whose shapes and advances follow
the axes in ways tests can measure:

- SivTest-VF.ttf (family "SivTest VF"): a variable font with wght 100..900 (stem width), wdth
  75..125 (body width), opsz 8..72 (side bearings: wider at small sizes),
  and slnt -12..0 (shear), default 400, 100, 14, 0.
- SivTest-Regular.ttf, SivTest-Bold.ttf, SivTest-Italic.ttf (family
  "SivTest"): static instances (the italic is the slnt -12 instance flagged italic).

Part of siv (MIT). Needs fontTools: python3 make_test_fonts.py
"""

import math
import os

from fontTools.designspaceLib import AxisDescriptor, DesignSpaceDocument, SourceDescriptor
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.varLib import build as build_variable
from fontTools.varLib.instancer import instantiateVariableFont

UPEM = 1000
GLYPHS = [".notdef", "space", "H", "I", "O", "n"]
CMAP = {0x20: "space", ord("H"): "H", ord("I"): "I", ord("O"): "O", ord("n"): "n"}
FAMILY = "SivTest"


def stem(wght):
    # 30 units at 100, 90 at 400, 200 at 900; linear on each side.
    return 30 + (wght - 100) * 60 / 300 if wght <= 400 else 90 + (wght - 400) * 110 / 500


def bearing(opsz):
    return 80 if opsz <= 8 else 30 if opsz >= 72 else 60


def rect(pen, x0, y0, x1, y1, shear, clockwise=True):
    pts = [(x0, y0), (x0, y1), (x1, y1), (x1, y0)]
    if not clockwise:
        pts.reverse()
    pen.moveTo(sheared(pts[0], shear))
    for p in pts[1:]:
        pen.lineTo(sheared(p, shear))
    pen.closePath()


def sheared(p, shear):
    x, y = p
    return (round(x + y * shear), round(y))


def master(wght=400, wdth=100, opsz=14, slnt=0):
    s = stem(wght)
    sb = bearing(opsz)
    wf = wdth / 100
    shear = math.tan(math.radians(-slnt))
    glyphs = {}
    advances = {}

    pen = TTGlyphPen(None)
    rect(pen, 50, 0, 450, 700, 0)
    rect(pen, 100, 50, 400, 650, 0, clockwise=False)
    glyphs[".notdef"] = pen.glyph()
    advances[".notdef"] = 500

    glyphs["space"] = TTGlyphPen(None).glyph()
    advances["space"] = round(250 * wf)

    pen = TTGlyphPen(None)
    rect(pen, sb, 0, sb + s, 700, shear)
    glyphs["I"] = pen.glyph()
    advances["I"] = round(2 * sb + s)

    body = 500 * wf
    pen = TTGlyphPen(None)
    rect(pen, sb, 0, sb + s, 700, shear)
    rect(pen, sb + body - s, 0, sb + body, 700, shear)
    rect(pen, sb + s, 330, sb + body - s, 330 + 0.8 * s, shear)
    glyphs["H"] = pen.glyph()
    advances["H"] = round(2 * sb + body)

    body = 520 * wf
    pen = TTGlyphPen(None)
    rect(pen, sb, 0, sb + body, 700, shear)
    rect(pen, sb + s, s, sb + body - s, 700 - s, shear, clockwise=False)
    glyphs["O"] = pen.glyph()
    advances["O"] = round(2 * sb + body)

    body = 420 * wf
    pen = TTGlyphPen(None)
    rect(pen, sb, 0, sb + s, 500, shear)
    rect(pen, sb + body - s, 0, sb + body, 500, shear)
    rect(pen, sb + s, 500 - 0.8 * s, sb + body - s, 500, shear)
    glyphs["n"] = pen.glyph()
    advances["n"] = round(2 * sb + body)

    fb = FontBuilder(UPEM, isTTF=True)
    fb.setupGlyphOrder(GLYPHS)
    fb.setupCharacterMap(CMAP)
    fb.setupGlyf(glyphs)
    glyf = fb.font["glyf"]
    metrics = {}
    for name in GLYPHS:
        g = glyf[name]
        g.recalcBounds(glyf)
        metrics[name] = (advances[name], getattr(g, "xMin", 0))
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": FAMILY, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, sTypoLineGap=0, usWinAscent=800, usWinDescent=200,
                sxHeight=500, sCapHeight=700, usWeightClass=400, usWidthClass=5)
    fb.setupPost()
    return fb.font


def variable():
    doc = DesignSpaceDocument()
    for tag, name, lo, default, hi in [("wght", "Weight", 100, 400, 900), ("wdth", "Width", 75, 100, 125),
                                       ("opsz", "Optical size", 8, 14, 72), ("slnt", "Slant", -12, 0, 0)]:
        axis = AxisDescriptor()
        axis.tag, axis.name, axis.minimum, axis.default, axis.maximum = tag, name, lo, default, hi
        doc.addAxis(axis)
    locations = [{}, {"wght": 100}, {"wght": 900}, {"wdth": 75}, {"wdth": 125}, {"opsz": 8}, {"opsz": 72}, {"slnt": -12}]
    names = {"wght": "Weight", "wdth": "Width", "opsz": "Optical size", "slnt": "Slant"}
    defaults = {"wght": 400, "wdth": 100, "opsz": 14, "slnt": 0}
    for i, loc in enumerate(locations):
        full = dict(defaults, **loc)
        src = SourceDescriptor()
        src.font = master(**full)
        src.name = f"master{i}"
        src.location = {names[k]: v for k, v in full.items()}
        doc.addSource(src)
    font, _, _ = build_variable(doc)
    return font


def rename(font, style, weight, italic, family=FAMILY):
    name = font["name"]
    for rec in list(name.names):
        if rec.nameID in (1, 2, 4, 6, 16, 17):
            name.removeNames(nameID=rec.nameID)
    name.setName(family, 1, 3, 1, 0x409)
    name.setName(style, 2, 3, 1, 0x409)
    name.setName(f"{family} {style}", 4, 3, 1, 0x409)
    name.setName(f"{family.replace(' ', '')}-{style.replace(' ', '')}", 6, 3, 1, 0x409)
    font["OS/2"].usWeightClass = weight
    sel = font["OS/2"].fsSelection & ~0b1100001
    sel |= 0b1 if italic else 0
    sel |= 0b100000 if weight >= 700 else 0
    sel |= 0b1000000 if not italic and weight < 700 else 0
    font["OS/2"].fsSelection = sel
    font["head"].macStyle = (1 if weight >= 700 else 0) | (2 if italic else 0)
    font["post"].italicAngle = -12 if italic else 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    vf = variable()
    rename(vf, "Regular", 400, False, family=FAMILY + " VF")
    vf.save(os.path.join(here, "SivTest-VF.ttf"))
    for style, loc, weight, italic in [("Regular", {"wght": 400}, 400, False), ("Bold", {"wght": 700}, 700, False),
                                       ("Italic", {"wght": 400, "slnt": -12}, 400, True)]:
        full = {"wght": 400, "wdth": 100, "opsz": 14, "slnt": 0}
        full.update(loc)
        inst = instantiateVariableFont(variable(), full)
        rename(inst, style, weight, italic)
        inst.save(os.path.join(here, f"SivTest-{style}.ttf"))


if __name__ == "__main__":
    main()
