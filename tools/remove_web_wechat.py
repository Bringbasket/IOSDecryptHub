#!/usr/bin/env python3
"""Hide the embedded Web UI WeChat entry without changing Mach-O size."""

from __future__ import annotations

import argparse
from pathlib import Path


SOURCE = (
    b"<div class='menu-wrap'>\n"
    b"      <button type='button' class='compact-action' id='wechatBtn'"
)
REPLACEMENT = (
    b"<div style='display:none'>\n"
    b"   <button type='button' class='compact-action' id='wechatBtn'"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="validate without writing")
    parser.add_argument("dylib", type=Path)
    args = parser.parse_args()

    if len(SOURCE) != len(REPLACEMENT):
        raise SystemExit("internal error: replacement changes Mach-O size")

    data = args.dylib.read_bytes()
    matches = data.count(SOURCE)
    already_hidden = data.count(REPLACEMENT)
    if matches == 0:
        if already_hidden:
            print(f"Web UI WeChat entry already hidden ({already_hidden} occurrence(s))")
            return 0
        raise SystemExit("embedded Web UI WeChat entry was not found")

    patched = data.replace(SOURCE, REPLACEMENT)
    if len(patched) != len(data) or SOURCE in patched:
        raise SystemExit("failed to create a size-preserving Web UI patch")

    if args.check:
        print(f"Web UI WeChat entry patchable ({matches} occurrence(s))")
        return 0

    args.dylib.write_bytes(patched)
    print(f"Web UI WeChat entry hidden ({matches} occurrence(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
