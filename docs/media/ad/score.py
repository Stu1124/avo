#!/usr/bin/env python3
"""Original 40s stereo bed for the Avo ad. No samples, no third-party loops."""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 48000
DURATION = 40.0
N = int(RATE * DURATION)


def clamp(v: float, lo: float = -1.0, hi: float = 1.0) -> float:
    return lo if v < lo else hi if v > hi else v


def env(i: int, attack: float, hold_end: float, release: float) -> float:
    t = i / RATE
    if t < attack:
        return t / attack
    if t < hold_end:
        return 1.0
    if t < DURATION:
        span = max(0.001, DURATION - hold_end)
        return max(0.0, 1.0 - (t - hold_end) / span) ** release
    return 0.0


def whoosh(i: int, center: float, width: float = 0.18) -> float:
    t = i / RATE
    x = (t - center) / width
    if x < -1 or x > 1:
        return 0.0
    # Raised-cosine burst of band-limited noise.
    n = math.sin(i * 0.031) + 0.55 * math.sin(i * 0.079) + 0.35 * math.sin(i * 0.141)
    return n * (0.5 + 0.5 * math.cos(x * math.pi)) * (0.5 + 0.5 * x)


def render(path: Path) -> None:
    left = []
    right = []
    cuts = (3.05, 6.75, 10.45, 15.45, 20.5, 25.45, 30.15, 34.35)
    for i in range(N):
        t = i / RATE
        air = (0.7 * math.sin(i * 12.973) + 0.3 * math.sin(i * 27.419)) * 0.004
        drone = math.sin(2 * math.pi * 55.0 * t) * 0.045
        fifth = math.sin(2 * math.pi * 82.4 * t + 0.2) * 0.028
        pad = math.sin(2 * math.pi * 220.0 * t + 0.4 * math.sin(2 * math.pi * 0.07 * t)) * 0.012
        shimmer = math.sin(2 * math.pi * 659.25 * t) * 0.0045 * (0.5 + 0.5 * math.sin(2 * math.pi * 0.11 * t))
        e = env(i, 1.2, 36.4, 1.6)
        bed = (drone + fifth + pad * min(1.0, max(0.0, (t - 7.5) / 4.0)) + shimmer + air) * e

        burst = 0.0
        for c in cuts:
            burst += whoosh(i, c, 0.16) * 0.035
        tick = 0.0
        if 0.42 <= t <= 0.62:
            tick = math.sin(2 * math.pi * 880 * t) * (1.0 - (t - 0.42) / 0.2) * 0.05

        pan = 0.15 * math.sin(2 * math.pi * 0.05 * t)
        sample = bed + burst + tick
        left.append(clamp(sample * (1.0 - pan)))
        right.append(clamp(sample * (1.0 + pan)))

    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "w") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for a, b in zip(left, right):
            frames += struct.pack("<hh", int(a * 32767), int(b * 32767))
        w.writeframes(frames)


if __name__ == "__main__":
    import sys
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/avo-ad-render/score.wav")
    render(out)
    print(out)
