#!/usr/bin/env python3
"""Dumps the AT-SPI tree of applications whose name contains a pattern:
role, name, and states, to a depth.

    python3 tools/atspi-dump.py PATTERN [DEPTH]
"""
import sys
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

pattern = sys.argv[1].lower()
depth = int(sys.argv[2]) if len(sys.argv) > 2 else 12


def dump(acc, d=0):
    if acc is None or d > depth:
        return
    try:
        role = acc.get_role_name()
        name = acc.get_name() or ""
        n = acc.get_child_count()
    except Exception as e:  # a remote tree that went away
        print("  " * d + f"<{e}>")
        return
    print("  " * d + f"[{role}] {name!r}" + (f" ({n} children)" if n else ""))
    for i in range(min(n, 40)):
        try:
            dump(acc.get_child_at_index(i), d + 1)
        except Exception as e:
            print("  " * (d + 1) + f"<{e}>")


desktop = Atspi.get_desktop(0)
found = False
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    if app and (pattern in (app.get_name() or "").lower() or (pattern == "-" and not app.get_name())):
        found = True
        dump(app)
if not found:
    print("no application matching", pattern, "among:", [desktop.get_child_at_index(i).get_name() for i in range(desktop.get_child_count()) if desktop.get_child_at_index(i)])
