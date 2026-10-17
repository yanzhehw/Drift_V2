#!/usr/bin/env python3
"""Generate Drift_V2 palette images (no third-party dependencies).

Drift colors each line by sampling its palette image at 0.5 + 2 * velocity,
mirrored at the edges: the direction of the flow picks the side of the image
and its speed picks the distance from the center. So these palettes arrange
their colors around the center by direction, with a gentle warp so the
boundaries swirl, and a fine grain so neighbouring lines vary slightly.

Lines are blended additively on black, so keep colors mid-to-bright: near
black disappears and near white blows out where lines overlap.

Usage:
    python3 drift/colors/make_palettes.py            # all palettes
    python3 drift/colors/make_palettes.py aurora     # just one
"""

import math
import random
import struct
import sys
import zlib
from pathlib import Path

SIZE = 256
GRAIN = 8  # max +/- per channel

# Colors go counter-clockwise starting from "flowing right".
PALETTES = {
    # Inspired by Apple's Drift screen saver.
    "space_gray": ["#5b6370", "#9aa3ae", "#d5dae1", "#737b88"],
    # From uiGradients (MIT): Lunada, Atlas, Quepal, Cool Sky, Flare.
    "aurora": ["#5433ff", "#20bdff", "#a5fecb"],
    "atlas": ["#feac5e", "#c779d0", "#4bc0c8"],
    "emerald": ["#11998e", "#38ef7d"],
    "glacier": ["#2980b9", "#6dd5fa", "#e6f4ff"],  # white softened so it doesn't blow out
    "ember": ["#f12711", "#f5af19"],
}

TAU = 2 * math.pi


def hex_to_rgb(color):
    return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))


def smoothstep(t):
    return t * t * (3 - 2 * t)


def render(name, stops):
    rng = random.Random(name)  # deterministic per palette
    colors = [hex_to_rgb(c) for c in stops]
    count = len(colors)
    p1, p2 = rng.random() * TAU, rng.random() * TAU

    rows = []
    for y in range(SIZE):
        row = bytearray([0])  # PNG filter type: none
        dy = 0.5 - (y + 0.5) / SIZE  # +y is up
        for x in range(SIZE):
            dx = (x + 0.5) / SIZE - 0.5
            warp = (0.5 * math.sin(TAU * (1.5 * dx + 0.8 * dy) + p1)
                    + 0.3 * math.sin(TAU * (2.1 * dy - 1.2 * dx) + p2))
            angle = ((math.atan2(dy, dx) + warp) / TAU) % 1.0

            f = angle * count
            i = int(f) % count
            t = smoothstep(f - math.floor(f))
            c0, c1 = colors[i], colors[(i + 1) % count]
            for k in range(3):
                value = c0[k] + (c1[k] - c0[k]) * t + rng.uniform(-GRAIN, GRAIN)
                row.append(max(0, min(255, round(value))))
        rows.append(bytes(row))
    return b"".join(rows)


def write_png(path, pixels):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit RGB
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(pixels, 9)) + chunk(b"IEND", b""))


def main(names):
    out_dir = Path(__file__).resolve().parent
    for name in names or PALETTES:
        if name not in PALETTES:
            sys.exit(f"unknown palette {name!r}; choose from {', '.join(PALETTES)}")
        path = out_dir / f"{name}.png"
        write_png(path, render(name, PALETTES[name]))
        print(f"wrote {path.name} ({path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main(sys.argv[1:])
