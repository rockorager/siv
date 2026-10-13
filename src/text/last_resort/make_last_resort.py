#!/usr/bin/env python3
"""Generates SivLastResort.ttf, the face siv draws text with when no font
resolves (D13): no font was added and Fontconfig finds none.

Its .notdef is a hollow box (0.6 em by 0.7 em above the baseline) that
every character maps to, so missing text still lays out and shows as
boxes; space and no-break space map to an empty glyph of a quarter em, so
words stay apart.

Part of siv (MIT). Needs fontTools: python3 make_last_resort.py
"""

import os

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

UPEM = 1000
FAMILY = "siv last resort"


def box():
    pen = TTGlyphPen(None)
    outer = [(50, 0), (50, 700), (550, 700), (550, 0)]
    inner = [(110, 60), (490, 60), (490, 640), (110, 640)]
    for contour in (outer, inner):
        pen.moveTo(contour[0])
        for p in contour[1:]:
            pen.lineTo(p)
        pen.closePath()
    return pen.glyph()


def main():
    fb = FontBuilder(UPEM, isTTF=True)
    fb.setupGlyphOrder([".notdef", "space"])
    fb.setupCharacterMap({0x20: "space", 0xA0: "space"})
    fb.setupGlyf({".notdef": box(), "space": TTGlyphPen(None).glyph()})
    fb.setupHorizontalMetrics({".notdef": (600, 50), "space": (250, 0)})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": FAMILY, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, sTypoLineGap=0, usWinAscent=800, usWinDescent=200, usWeightClass=400)
    fb.setupPost()
    fb.font.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), "SivLastResort.ttf"))


if __name__ == "__main__":
    main()
