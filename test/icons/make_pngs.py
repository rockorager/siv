#!/usr/bin/env python3
"""Writes the PNG icons of siv's test themes (test/icons/themes).

Run from this directory. The icons are drawn here, pixel by pixel, so
they are siv's own (MIT), like the SVGs next to them.
"""
import struct
import zlib


def png(path, w, h, fn):
    raw = b''.join(b'\x00' + bytes(sum((fn(x, y) for x in range(w)), ())) for y in range(h))

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def page(n):
    """A page with a green plus, at n pixels."""
    def f(x, y):
        u, v = x / n, y / n
        if 0.25 <= u <= 0.8 and 0.1 <= v <= 0.92:
            if (abs(u - 0.52) < 0.06 and 0.4 < v < 0.75) or (abs(v - 0.57) < 0.06 and 0.35 < u < 0.7):
                return (0x26, 0xa2, 0x69, 255)
            edge = min(u - 0.25, 0.8 - u, v - 0.1, 0.92 - v) < 1.0 / n
            return (0x77, 0x76, 0x7b, 255) if edge else (255, 255, 255, 255)
        return (0, 0, 0, 0)
    return f


def app(x, y):
    dx, dy = x - 23.5, y - 23.5
    d = (dx * dx + dy * dy) ** 0.5
    if d > 22:
        return (0, 0, 0, 0)
    return (0xe6, 0x61 + int(d * 3), 0x00, 255)


png('themes/SivTest/16x16/actions/document-new.png', 16, 16, page(16))
png('themes/SivTest/16x16@2/actions/document-new.png', 32, 32, page(32))
png('themes/hicolor/48x48/apps/siv-test-app.png', 48, 48, app)
