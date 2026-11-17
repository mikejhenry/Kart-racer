#!/usr/bin/env python3
"""Synthesizes all of the game's sound effects and music into audio/.

Everything is generated from oscillators and noise (no samples), so the
sounds are original and can be tweaked here and regenerated:

    python3 tools/make_audio.py

Needs numpy and scipy, plus ffmpeg with libvorbis for the music (.ogg).
"""
import os
import subprocess
import wave

import numpy as np
from scipy.signal import lfilter

RATE = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "audio")
rng = np.random.default_rng(42)


# --- building blocks ---------------------------------------------------------

def t_axis(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def osc(freq, seconds, shape="sine"):
    """Oscillator; freq can be a number or an array (for sweeps)."""
    n = int(seconds * RATE)
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,))
    phase = np.cumsum(f) / RATE
    if shape == "sine":
        return np.sin(2 * np.pi * phase)
    if shape == "square":
        return np.sign(np.sin(2 * np.pi * phase))
    if shape == "saw":
        return 2.0 * (phase % 1.0) - 1.0
    if shape == "tri":
        return 2.0 * np.abs(2.0 * (phase % 1.0) - 1.0) - 1.0
    raise ValueError(shape)


def noise(seconds):
    return rng.uniform(-1, 1, int(seconds * RATE))


def lowpass(x, cutoff):
    """One-pole low-pass filter. cutoff can be a number or a per-sample array."""
    if np.ndim(cutoff) == 0:
        a = np.exp(-2 * np.pi * cutoff / RATE)
        return lfilter([1 - a], [1, -a], x)
    a = np.exp(-2 * np.pi * np.asarray(cutoff) / RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a[i]) * v + a[i] * acc
        y[i] = acc
    return y


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


def env(seconds, attack=0.005, release=None, curve=1.0):
    """Attack then decay to silence over the clip."""
    n = int(seconds * RATE)
    e = np.ones(n)
    a = max(1, int(attack * RATE))
    e[:a] = np.linspace(0, 1, a)
    r = n - a if release is None else int(release * RATE)
    e[n - r:] *= np.linspace(1, 0, r) ** curve
    return e


def note(name):
    """Frequency of a note like 'A4' or 'C#5'."""
    names = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3,
             "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}
    pitch, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((names[pitch] + 12 * (octave - 4)) / 12)


def loopify(x, fade=0.04):
    """Crossfades the extra tail into the start so the clip loops without a click."""
    f = int(fade * RATE)
    body = x[:-f].copy()
    ramp = np.linspace(0, 1, f)
    body[:f] = body[:f] * ramp + x[-f:] * (1 - ramp)
    return body


def seq(parts):
    return np.concatenate(parts)


def save_wav(name, x, peak=0.9):
    x = np.asarray(x, dtype=float)
    m = np.max(np.abs(x)) or 1.0
    data = (x / m * peak * 32767).astype("<i2")
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data.tobytes())
    return path


def save_ogg(name, x, peak=0.85):
    tmp = save_wav("_tmp_" + name, x, peak)
    path = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c:a", "libvorbis", "-q:a", "3", path], check=True)
    os.remove(tmp)


# --- sound effects -----------------------------------------------------------

def engine():
    # 0.4 s loops cleanly: 22 cycles of 55 Hz, 44 of 110 Hz.
    d = 0.44  # 0.4 s loop + 0.04 s crossfade
    x = 0.6 * osc(55, d, "saw") + 0.35 * osc(110, d, "square") + 0.15 * osc(165, d, "saw")
    x += 0.12 * noise(d)
    return loopify(lowpass(x, 900))


def drift():
    d = 0.64  # 0.6 s loop + 0.04 s crossfade
    x = highpass(noise(d), 1800)
    x = lowpass(x, 4200)
    return loopify(x * (0.7 + 0.3 * osc(20, d)))


def boost():
    d = 0.6
    t = t_axis(d)
    x = lowpass(noise(d), 600 + 3000 * t / d) * 0.8 + 0.3 * osc(200 + 600 * t / d, d, "saw")
    return x * env(d, 0.05, 0.4)


def item_get():
    parts = [osc(note(n), 0.08, "square") * env(0.08, 0.002, 0.06) for n in ("C6", "E6", "G6", "C7")]
    return seq(parts)


def roulette():
    return osc(1800, 0.035, "square") * env(0.035, 0.001, 0.03)


def missile():
    d = 0.5
    t = t_axis(d)
    x = 0.6 * lowpass(noise(d), 1500) + 0.4 * osc(1400 - 900 * t / d, d, "saw")
    return x * env(d, 0.01, 0.45)


def hit():
    d = 0.6
    t = t_axis(d)
    x = 0.6 * osc(500 * (1 - 0.8 * t / d), d, "square") + 0.5 * lowpass(noise(d), 2500) * env(d, 0.001, 0.3, 2)
    return x * env(d, 0.002, 0.55)


def oil():
    d = 0.35
    t = t_axis(d)
    x = osc(220 - 140 * t / d + 25 * np.sin(2 * np.pi * 18 * t), d, "sine")
    return x * env(d, 0.005, 0.3)


def shield():
    d = 0.5
    t = t_axis(d)
    x = sum(osc(f * (1 + 0.3 * t / d), d, "tri") for f in (523, 659, 784))
    return x * (0.6 + 0.4 * osc(30, d)) * env(d, 0.02, 0.4)


def storm():
    d = 0.8
    crack = noise(d) * env(d, 0.0005, 0.25 * 0 + d, 6)
    rumble = lowpass(noise(d), 200) * 3.0 * env(d, 0.05, 0.7)
    return crack + rumble


def bump():
    d = 0.16
    t = t_axis(d)
    return (osc(110 - 50 * t / d, d) + 0.4 * lowpass(noise(d), 800)) * env(d, 0.001, 0.15, 2)


def land():
    d = 0.22
    t = t_axis(d)
    return (osc(80 - 30 * t / d, d) + 0.5 * lowpass(noise(d), 500)) * env(d, 0.001, 0.2, 2)


def pad():
    d = 0.35
    t = t_axis(d)
    return osc(300 + 1100 * t / d, d, "saw") * env(d, 0.005, 0.25) * 0.8


def beep():
    return osc(660, 0.18, "square") * env(0.18, 0.003, 0.08)


def go():
    return osc(1320, 0.45, "square") * env(0.45, 0.003, 0.3)


def lap():
    return seq([osc(note("G5"), 0.12, "tri") * env(0.12, 0.003, 0.1),
                osc(note("D6"), 0.35, "tri") * env(0.35, 0.003, 0.3)])


def finish():
    parts = [osc(note(n), 0.13, "square") * env(0.13, 0.003, 0.1) for n in ("C5", "E5", "G5", "C6", "E6", "G6")]
    chord = sum(osc(note(n), 1.0, "tri") for n in ("C5", "E5", "G5", "C6")) * env(1.0, 0.01, 0.9)
    return seq(parts + [chord])


def click():
    return osc(1000, 0.04, "tri") * env(0.04, 0.001, 0.035)


# --- music -------------------------------------------------------------------

def kick(d):
    t = t_axis(d)
    return osc(120 * np.exp(-t * 18) + 40, d) * env(d, 0.001, d, 3)


def snare(d):
    return (0.8 * highpass(noise(d), 1000) + 0.3 * osc(190, d, "tri")) * env(d, 0.001, d, 4)


def hat(d):
    return highpass(noise(d), 6000) * env(d, 0.001, d, 6) * 0.5


def render_track(bpm, bars, chords, melody, lead_shape, drums=True, bass_pattern="eighths"):
    """chords: one chord (list of note names) per bar.
    melody: list of (note or None, length in beats), looped to fill."""
    beat = 60.0 / bpm
    total = int(bars * 4 * beat * RATE)
    mix = np.zeros(total)

    def place(x, start_beat, gain=1.0):
        s = int(start_beat * beat * RATE)
        e = min(total, s + len(x))
        mix[s:e] += x[: e - s] * gain

    for bar, chord in enumerate(chords[:bars]):
        root = note(chord[0][:-1] + str(int(chord[0][-1]) - 1))
        # Bass
        steps = 8 if bass_pattern == "eighths" else 4
        for i in range(steps):
            length = 4 / steps
            f = root * (2 if (bass_pattern == "eighths" and i % 2) else 1)
            x = osc(f, length * beat * 0.9, "square") * env(length * beat * 0.9, 0.003, length * beat * 0.5)
            place(lowpass(x, 700), bar * 4 + i * length, 0.32)
        # Pad chord
        pad_x = sum(osc(note(n), 4 * beat, "tri") for n in chord) * env(4 * beat, 0.08, 1.5 * beat)
        place(lowpass(pad_x, 1500), bar * 4, 0.12)
        if drums:
            for b in range(4):
                place(kick(0.25), bar * 4 + b, 0.5 if b % 2 == 0 else 0.0)
                if b % 2 == 1:
                    place(snare(0.2), bar * 4 + b, 0.35)
                for h in (0, 0.5):
                    place(hat(0.06), bar * 4 + b + h, 0.25)

    pos = 0.0
    i = 0
    while pos < bars * 4:
        n, length = melody[i % len(melody)]
        if n is not None:
            d = length * beat * 0.95
            x = osc(note(n), d, lead_shape) * env(d, 0.004, min(d, 0.25)) * 0.9
            x += 0.15 * osc(note(n) * 2, d, "sine") * env(d, 0.004, min(d, 0.2))
            place(x, pos, 0.22)
        pos += length
        i += 1
    return mix


def music_race():
    chords = [["A4", "C5", "E5"], ["F4", "A4", "C5"], ["C4", "E4", "G4"], ["G4", "B4", "D5"]] * 4
    melody = [
        ("A5", 0.5), ("C6", 0.5), ("E6", 1), ("D6", 0.5), ("C6", 0.5), ("A5", 1),
        ("F5", 0.5), ("A5", 0.5), ("C6", 1), ("E6", 0.5), ("D6", 0.5), ("C6", 1),
        ("G5", 0.5), ("C6", 0.5), ("E6", 1), ("G6", 1), ("E6", 1),
        ("D6", 0.5), ("B5", 0.5), ("G5", 1), ("B5", 0.5), ("D6", 0.5), ("G6", 1),
        ("A5", 1), ("E6", 1), ("C6", 0.5), ("B5", 0.5), ("A5", 1),
        ("F5", 1), ("A5", 0.5), ("C6", 0.5), ("F6", 1), ("E6", 1),
        ("E6", 0.5), ("D6", 0.5), ("C6", 0.5), ("D6", 0.5), ("E6", 1), ("G6", 1),
        ("G6", 0.5), ("F#6", 0.5), ("D6", 1), ("B5", 1), (None, 1),
    ]
    return render_track(148, 16, chords, melody, "square")


def music_menu():
    chords = [["C5", "E5", "G5"], ["A4", "C5", "E5"], ["F4", "A4", "C5"], ["G4", "B4", "D5"]] * 2
    melody = [
        ("E5", 1), ("G5", 1), ("C6", 2),
        ("A5", 1), ("C6", 1), ("E6", 2),
        ("F5", 1), ("A5", 1), ("C6", 1.5), ("A5", 0.5),
        ("B5", 1), ("D6", 1), ("G5", 2),
        ("E6", 1.5), ("D6", 0.5), ("C6", 2),
        ("C6", 1), ("E6", 1), ("A5", 2),
        ("A5", 1), ("C6", 1), ("F6", 1), ("E6", 1),
        ("D6", 2), ("G5", 2),
    ]
    return render_track(96, 8, chords, melody, "tri", drums=False, bass_pattern="quarters")


def main():
    os.makedirs(OUT, exist_ok=True)
    effects = {
        "engine": engine, "drift": drift, "boost": boost, "item_get": item_get, "roulette": roulette,
        "missile": missile, "hit": hit, "oil": oil, "shield": shield, "storm": storm, "bump": bump,
        "land": land, "pad": pad, "beep": beep, "go": go, "lap": lap, "finish": finish, "click": click,
    }
    for name, fn in effects.items():
        save_wav(name, fn())
        print("wrote", name + ".wav")
    save_ogg("music_race", music_race())
    print("wrote music_race.ogg")
    save_ogg("music_menu", music_menu())
    print("wrote music_menu.ogg")


if __name__ == "__main__":
    main()
