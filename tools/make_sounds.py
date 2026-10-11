#!/usr/bin/env python3
"""Synthesises the built-in soundboard sounds (no recordings, so no licensing issues).

Usage: python3 tools/make_sounds.py   (needs numpy; writes mac-helper/Resources/Sounds/*.m4a via afconvert)
"""
import os
import subprocess
import tempfile
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "mac-helper", "Resources", "Sounds")
rng = np.random.default_rng(7)


def t(sec):
    return np.arange(int(sec * SR)) / SR


def env_adsr(n, a=0.01, d=0.1, s=0.7, r=0.2):
    a, d, r = int(a * SR), int(d * SR), int(r * SR)
    sus = max(0, n - a - d - r)
    e = np.concatenate([np.linspace(0, 1, a, endpoint=False), np.linspace(1, s, d, endpoint=False),
                        np.full(sus, s), np.linspace(s, 0, r)])
    return np.pad(e, (0, max(0, n - len(e))))[:n]


def lowpass(x, cutoff):
    # Simple one-pole filter, applied twice for a softer slope.
    a = np.exp(-2 * np.pi * cutoff / SR)
    for _ in range(2):
        y = np.zeros_like(x)
        acc = 0.0
        for i in range(len(x)):
            acc = (1 - a) * x[i] + a * acc
            y[i] = acc
        x = y
    return x


def fft_filter(x, lo, hi):
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    spec[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(spec, len(x))


def brass(freq, sec, vib=0.0):
    tt = t(sec)
    ph = 2 * np.pi * np.cumsum(freq * (1 + vib * np.sin(2 * np.pi * 5.5 * tt))) / SR
    tone = sum((1 / k ** 1.2) * np.sin(k * ph) for k in range(1, 12))
    # Brightness opens up with the attack, like a real horn.
    bright = sum((1 / k) * np.sin(k * ph) for k in range(4, 12)) * np.minimum(1, tt * 12)
    return (tone + 0.4 * bright) * env_adsr(len(tt), 0.03, 0.08, 0.8, 0.12)


def normalize(x, peak=0.89):
    x = x - np.mean(x)
    return x * (peak / (np.max(np.abs(x)) + 1e-9))


def applause(sec=4.5):
    n = int(sec * SR)
    x = np.zeros(n)
    # Crowd density rises quickly and fades out.
    times = []
    tcur = 0.0
    while tcur < sec - 0.05:
        density = 70 * min(1, tcur / 0.4) * (1 if tcur < sec - 1.8 else max(0.05, (sec - tcur) / 1.8))
        tcur += rng.exponential(1 / max(density, 3))
        times.append(tcur)
    for c in times:
        i = int(c * SR)
        ln = int(SR * rng.uniform(0.006, 0.018))
        if i + ln >= n:
            continue
        burst = rng.standard_normal(ln) * np.exp(-np.linspace(0, rng.uniform(5, 9), ln))
        x[i:i + ln] += burst * rng.uniform(0.3, 1.0)
    x = fft_filter(x, 500, 7000)
    bed = fft_filter(rng.standard_normal(n), 800, 5000) * 0.05 * env_adsr(n, 0.4, 0.2, 1, 1.6)
    return normalize(x + bed)


def snare(sec=0.12, amp=1.0):
    tt = t(sec)
    noise = fft_filter(rng.standard_normal(len(tt)), 1500, 9000) * np.exp(-tt * 28)
    body = np.sin(2 * np.pi * 190 * tt) * np.exp(-tt * 40)
    return amp * (noise + 0.6 * body)


def crash(sec=2.2):
    tt = t(sec)
    noise = fft_filter(rng.standard_normal(len(tt)), 3000, 14000)
    return noise * np.exp(-tt * 2.2)


def drumroll(sec=2.6):
    n = int((sec + 2.2) * SR)
    x = np.zeros(n)
    tcur = 0.0
    while tcur < sec:
        amp = 0.25 + 0.75 * (tcur / sec) ** 1.5
        s = snare(0.1, amp * rng.uniform(0.85, 1.0))
        i = int(tcur * SR)
        x[i:i + len(s)] += s[: n - i]
        tcur += 1 / (16 + 10 * tcur / sec)
    c = crash()
    i = int(sec * SR)
    x[i:i + len(c)] += 1.6 * c[: n - i]
    k = snare(0.25, 1.4)
    x[i:i + len(k)] += k
    return normalize(x)


def bell(freq, sec):
    tt = t(sec)
    partials = [(1, 1.0, 3.0), (2.0, 0.5, 4.5), (3.01, 0.3, 6), (4.17, 0.18, 8), (5.43, 0.1, 10)]
    return sum(a * np.sin(2 * np.pi * freq * r * tt) * np.exp(-tt * d) for r, a, d in partials) * np.minimum(1, tt * 400)


def correct():
    a = bell(1318.5, 1.2)  # E6
    b = bell(1760.0, 1.6)  # A6
    x = np.zeros(int(SR * 1.9))
    x[: len(a)] += a
    i = int(0.16 * SR)
    x[i:i + len(b)] += b[: len(x) - i]
    return normalize(x, 0.8)


def wrong():
    out = []
    for f, sec in [(196, 0.32), (147, 0.55)]:
        tt = t(sec)
        sq = np.sign(np.sin(2 * np.pi * f * tt)) * 0.6 + np.sign(np.sin(2 * np.pi * f * 1.007 * tt)) * 0.4
        out.append(lowpass(sq, 2200) * env_adsr(len(tt), 0.005, 0.05, 0.9, 0.06))
        out.append(np.zeros(int(0.05 * SR)))
    return normalize(np.concatenate(out), 0.75)


def tada():
    notes = [(523.25, 0.11), (659.25, 0.11), (783.99, 0.11)]
    parts = [brass(f, s) for f, s in notes]
    chord = sum(brass(f, 1.3, vib=0.004) for f in [523.25, 659.25, 783.99, 1046.5]) / 2.2
    return normalize(np.concatenate(parts + [chord]))


def sad_trombone():
    parts = []
    for f, sec, vib in [(392.0, 0.42, 0), (369.99, 0.42, 0), (349.23, 0.42, 0), (329.63, 1.5, 0.02)]:
        tt = t(sec)
        b = brass(f / 2, sec, vib)
        wah = 0.55 + 0.45 * np.sin(np.pi * np.minimum(1, tt / min(sec, 0.42)))  # "wah" swell per note
        parts.append(b * wah)
    return normalize(lowpass(np.concatenate(parts), 1800))


def crickets(sec=3.2):
    n = int(sec * SR)
    x = np.zeros(n)
    tt = t(sec)
    for start in np.arange(0.1, sec - 0.3, 0.55):
        for k in range(3):  # three pulses per chirp
            i = int((start + k * 0.045) * SR)
            ln = int(0.028 * SR)
            if i + ln >= n:
                continue
            seg = np.sin(2 * np.pi * 4600 * tt[:ln]) * np.sin(np.pi * np.linspace(0, 1, ln)) ** 2
            x[i:i + ln] += seg
    return normalize(x, 0.6)


def gong(sec=4.0):
    tt = t(sec)
    f0 = 98
    partials = [(1, 1, 0.9), (1.47, 0.6, 1.1), (2.09, 0.5, 1.3), (2.56, 0.35, 1.6), (3.31, 0.3, 2), (4.12, 0.2, 2.5)]
    x = sum(a * np.sin(2 * np.pi * f0 * r * tt * (1 + 0.002 * np.exp(-tt))) * np.exp(-tt * d) for r, a, d in partials)
    shimmer = fft_filter(rng.standard_normal(len(tt)), 2000, 8000) * 0.05 * np.exp(-tt * 1.5)
    return normalize((x + shimmer) * np.minimum(1, tt * 200))


SOUNDS = {
    "applause": applause,
    "drumroll": drumroll,
    "correct": correct,
    "wrong": wrong,
    "tada": tada,
    "sad-trombone": sad_trombone,
    "crickets": crickets,
    "gong": gong,
}


def write(name, x):
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        out = os.path.join(OUT, name + ".m4a")
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000", wav, out], check=True)
    print(f"{name}: {len(x) / SR:.1f} s -> {os.path.getsize(out) // 1024} KB")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in SOUNDS.items():
        write(name, fn())
