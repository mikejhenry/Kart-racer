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


# --- race music: drum and bass / jungle ---------------------------------------
#
# 174 BPM in F minor, rendered in stereo at 44.1 kHz. Everything is still
# synthesized here: a two-step beat and a chopped jungle break built from
# synth drum hits, a growling "reese" bass (detuned saws through a moving
# resonant filter) over a sine sub, a kick-ducked pad, rave stabs, a
# delayed pluck arpeggio and a lead hook. 40 bars (about 55 s); the last
# bar's fill leads straight back into the first, so it loops seamlessly.

SR = 44100
DNB_BPM = 174.0
STEP = 60.0 / DNB_BPM / 4          # one sixteenth note in seconds
mrng = np.random.default_rng(174)


def m_t(seconds):
    return np.arange(int(seconds * SR)) / SR


def m_osc(freq, seconds, shape="sine", phase0=0.0):
    n = int(seconds * SR)
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,))
    ph = phase0 + np.cumsum(f) / SR
    if shape == "sine":
        return np.sin(2 * np.pi * ph)
    if shape == "saw":
        return 2.0 * (ph % 1.0) - 1.0
    if shape == "square":
        return np.sign(np.sin(2 * np.pi * ph))
    if shape == "tri":
        return 2.0 * np.abs(2.0 * (ph % 1.0) - 1.0) - 1.0
    raise ValueError(shape)


def m_noise(seconds):
    return mrng.uniform(-1, 1, int(seconds * SR))


def m_env(seconds, attack=0.002, decay=None, curve=1.0, hold=0.0):
    n = int(seconds * SR)
    e = np.ones(n)
    a = max(1, int(attack * SR))
    e[:a] = np.linspace(0, 1, a)
    h = int(hold * SR)
    d = n - a - h if decay is None else min(n - a - h, int(decay * SR))
    if d > 0:
        e[a + h:a + h + d] = np.linspace(1, 0, d) ** curve
        e[a + h + d:] = 0.0
    return e


def _biquad(kind, f, q):
    f = min(max(f, 20.0), SR * 0.45)
    w = 2 * np.pi * f / SR
    alpha = np.sin(w) / (2 * q)
    c = np.cos(w)
    if kind == "lp":
        b = [(1 - c) / 2, 1 - c, (1 - c) / 2]
    elif kind == "hp":
        b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]
    else:  # band-pass
        b = [alpha, 0.0, -alpha]
    a = [1 + alpha, -2 * c, 1 - alpha]
    return np.array(b) / a[0], np.array(a) / a[0]


def m_filter(x, kind, cutoff, q=0.707, block=256):
    """Resonant biquad; cutoff may be an array (swept, updated per block)."""
    if np.ndim(cutoff) == 0:
        b, a = _biquad(kind, float(cutoff), q)
        return lfilter(b, a, x)
    y = np.empty_like(x)
    zi = np.zeros(2)
    for i in range(0, len(x), block):
        b, a = _biquad(kind, float(cutoff[i]), q)
        y[i:i + block], zi = lfilter(b, a, x[i:i + block], zi=zi)
    return y


def nf(n):
    return note(n)


# Drum hits ------------------------------------------------------------------

def d_kick():
    d = 0.32
    t = m_t(d)
    body = m_osc(48 + 140 * np.exp(-t * 30), d) * m_env(d, 0.001, d, 2.2)
    click = m_filter(m_noise(0.008), "hp", 3000) * np.linspace(1, 0, int(0.008 * SR))
    body[:len(click)] += click * 0.5
    return np.tanh(body * 1.8)


def d_snare(tone=210.0, bright=1.0):
    d = 0.22
    t = m_t(d)
    body = m_osc(tone * (1 + 0.6 * np.exp(-t * 60)), d, "tri") * m_env(d, 0.001, 0.09, 2)
    sn = m_filter(m_noise(d), "bp", 3200 * bright, 0.8) * m_env(d, 0.001, d, 3)
    crack = m_filter(m_noise(d), "hp", 6000) * m_env(d, 0.001, 0.05, 2)
    return np.tanh((0.7 * body + 1.2 * sn + 0.5 * crack) * 1.6)


def d_hat(open_=False):
    d = 0.18 if open_ else 0.045
    x = m_filter(m_noise(d), "hp", 8000)
    return x * m_env(d, 0.001, d, 2.5 if open_ else 4)


def d_ride():
    d = 0.35
    x = sum(m_osc(f, d, "square") for f in (2953, 3721, 4419, 5303)) / 4
    x = m_filter(x + 0.4 * m_noise(d), "hp", 5000)
    return x * m_env(d, 0.001, d, 3)


def d_crash():
    d = 1.6
    x = m_filter(m_noise(d), "hp", 4500) + 0.3 * m_filter(m_noise(d), "bp", 9000, 2)
    return x * m_env(d, 0.002, d, 2.2)


def roomify(x, amount=0.18):
    """A small, dense room: a few short feedback echoes, low-passed."""
    out = x.copy()
    for ms, g in ((11.0, 0.5), (17.0, 0.42), (23.0, 0.35), (31.0, 0.28), (43.0, 0.2)):
        k = int(ms / 1000 * SR)
        y = np.zeros_like(x)
        y[k:] = x[:-k] * g
        out += lowpass_sr(y, 5000) * amount
    return out


def lowpass_sr(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    return lfilter([1 - a], [1, -a], x)


# Song -----------------------------------------------------------------------

# Two bars per chord: Fm9, Dbmaj7, Bbm9, C7sus4 -> C
CHORDS = [
    ("F2", ["Ab4", "C5", "Eb5", "G5"]),
    ("C#2", ["F4", "Ab4", "C5", "Eb5"]),
    ("A#1", ["C#4", "F4", "Ab4", "C5"]),
    ("C2", ["E4", "G4", "A#4", "C5"]),
]


def _fix(n):
    # note() knows sharps only
    return (n.replace("Ab", "G#").replace("Eb", "D#").replace("Db", "C#")
             .replace("Bb", "A#").replace("Gb", "F#"))


def chord_at(bar):
    root, tones = CHORDS[(bar // 2) % 4]
    return nf(_fix(root)), [nf(_fix(n)) for n in tones]


# Sixteenth-step patterns: (step, gain)
TWO_STEP = {
    "kick": [(0, 1.0), (10, 0.95)],
    "snare": [(4, 1.0), (12, 1.0), (7, 0.18), (15, 0.22), (9, 0.12)],
}
JUNGLE = [  # chopped break, two bars
    {"kick": [(0, 1.0), (2, 0.7), (10, 0.9), (11, 0.6)],
     "snare": [(4, 1.0), (7, 0.45), (9, 0.4), (12, 1.0), (14, 0.35)]},
    {"kick": [(0, 1.0), (3, 0.6), (8, 0.8), (10, 0.9)],
     "snare": [(4, 1.0), (6, 0.4), (12, 1.0), (13, 0.35), (15, 0.6)]},
]

LEAD = [  # (step within 4 bars, sixteenths long, note) - the hook
    (0, 3, "C6"), (3, 3, "D#6"), (6, 2, "F6"), (8, 6, "G6"), (14, 2, "F6"),
    (16, 3, "D#6"), (19, 3, "F6"), (22, 2, "D#6"), (24, 8, "C6"),
    (32, 3, "C#6"), (35, 3, "C6"), (38, 2, "A#5"), (40, 6, "C6"), (46, 2, "C#6"),
    (48, 3, "C6"), (51, 3, "A#5"), (54, 2, "G5"), (56, 8, "G5"),
]


def music_race():
    bars = 40
    bar_len = 16 * STEP
    total = int(bars * bar_len * SR) + SR * 2   # tail folded back into the start
    L = np.zeros(total)
    R = np.zeros(total)
    duck = np.ones(total)                      # sidechain from the kick

    def put(x, t, gain=1.0, pan=0.0):
        s = int(round(t * SR))
        e = min(total, s + len(x))
        if e <= s:
            return
        seg = x[: e - s] * gain
        L[s:e] += seg * np.sqrt(0.5 * (1 - pan))
        R[s:e] += seg * np.sqrt(0.5 * (1 + pan))

    kick = d_kick()
    snares = [roomify(d_snare(tone, br)) for tone, br in ((210, 1.0), (230, 1.15), (190, 0.9))]
    hat_c, hat_o, ride, crash = d_hat(), d_hat(True), d_ride(), d_crash()

    def section(bar):
        if bar < 8:
            return "drop_a"
        if bar < 16:
            return "jungle"
        if bar < 20:
            return "break"
        if bar < 32:
            return "drop_b"
        return "drop_a2"

    # --- drums ---
    for bar in range(bars):
        sec = section(bar)
        t0 = bar * bar_len
        last_of_8 = bar % 8 == 7
        if sec == "break":
            # Half-time, muffled beat, filtered hats and a snare roll into the drop.
            if bar < 18:
                put(lowpass_sr(kick, 300), t0, 0.7)
                put(lowpass_sr(snares[0], 1200), t0 + 8 * STEP, 0.5)
            for st in range(0, 16, 2):
                put(hat_c, t0 + st * STEP, 0.25, 0.3)
            if bar == 19:
                for st in range(16):
                    g = 0.15 + 0.7 * st / 15
                    put(snares[1], t0 + st * STEP, g)
            elif bar == 18:
                for st in range(0, 16, 2):
                    put(snares[0], t0 + st * STEP, 0.1 + 0.2 * st / 16)
            continue
        if sec == "jungle" or sec == "drop_b":
            pat = JUNGLE[bar % 2]
        else:
            pat = TWO_STEP
        kicks = list(pat["kick"])
        snr = list(pat["snare"])
        if last_of_8:
            # Fill: drop the second half and roll the snares.
            kicks = [k for k in kicks if k[0] < 8]
            snr = [s_ for s_ in snr if s_[0] < 8] + [(8, 0.7), (10, 0.6), (11, 0.5), (12, 0.9), (13, 0.6), (14, 0.8), (15, 0.9)]
        for st, g in kicks:
            put(kick, t0 + st * STEP, 1.0 * g)
            s = int((t0 + st * STEP) * SR)
            dl = int(0.16 * SR)
            e = min(total, s + dl)
            duck[s:e] = np.minimum(duck[s:e], 1 - 0.55 * g * np.linspace(1, 0, dl)[: e - s] ** 1.5)
        for st, g in snr:
            which = 0 if g > 0.8 else (2 if st % 2 else 1)
            put(snares[which], t0 + st * STEP + (0.004 if g < 0.5 else 0.0), 0.75 * g, mrng.uniform(-0.1, 0.1))
        # Hats: shuffled sixteenths in the jungle sections, offbeat eighths otherwise.
        for st in range(16):
            swing = STEP * 0.12 if st % 2 else 0.0
            if sec in ("jungle", "drop_b"):
                g = (0.22 if st % 4 == 2 else 0.11) * mrng.uniform(0.8, 1.1)
                put(hat_c, t0 + st * STEP + swing, g, 0.35)
            elif st % 4 == 2:
                put(hat_c, t0 + st * STEP, 0.26, 0.35)
        if sec in ("drop_a", "drop_a2", "drop_b"):
            for q in range(4):
                put(ride, t0 + q * 4 * STEP, 0.12, -0.4)
        if sec in ("jungle",) and bar % 2 == 1:
            put(hat_o, t0 + 14 * STEP, 0.2, 0.35)
        if bar in (0, 8, 20, 32):
            put(crash, t0, 0.32, -0.2)

    # --- sub and reese bass ---
    bass_l = np.zeros(total)
    bass_r = np.zeros(total)
    sub = np.zeros(total)
    for bar in range(bars):
        if section(bar) == "break" and bar < 18:
            # Just the sub, held under the breakdown.
            root, _ = chord_at(bar)
            d = bar_len
            x = m_osc(root, d) * m_env(d, 0.05, 0.1, 1.0, hold=d - 0.16)
            s = int(bar * bar_len * SR)
            sub[s:s + len(x)] += x * 0.8
            continue
        root, _ = chord_at(bar)
        t0 = bar * bar_len
        # Rhythm per bar (start step, length, octave shift in semitones)
        if bar % 2 == 0:
            notes = [(0, 10, 0), (10, 6, 0)]
        else:
            notes = [(0, 6, 0), (6, 4, 12), (10, 6, 7)] if bar % 8 != 7 else [(0, 8, 0), (8, 8, -2)]
        if section(bar) == "break":
            notes = [(8, 8, 0)]
        for st, ln, semi in notes:
            f = root * 2 ** (semi / 12)
            d = ln * STEP * 0.98
            n = int(d * SR)
            # Slight pitch scoop into each note.
            glide = f * (1 - 0.06 * np.exp(-m_t(d) * 40))
            e = m_env(d, 0.004, 0.03, 1.0, hold=d - 0.04)
            sub_x = m_osc(glide, d) * e
            s = int((t0 + st * STEP) * SR)
            ee = min(total, s + n)
            sub[s:ee] += sub_x[: ee - s]
            for side, det in ((bass_l, -0.18), (bass_r, 0.18)):
                x = (m_osc(glide * 2 ** (det / 12), d, "saw") + m_osc(glide * 2 ** (-det / 12) * 2, d, "saw", 0.3) * 0.6) * e
                side[s:ee] += x[: ee - s]
    # Moving resonant filter: an LFO across each bar plus wobbles in the jungle part.
    tt = np.arange(total) / SR
    lfo = 0.5 - 0.5 * np.cos(2 * np.pi * tt / (2 * bar_len))
    fast = 0.5 - 0.5 * np.cos(2 * np.pi * tt / (bar_len / 2))
    cutoff = 220 + 900 * lfo + 500 * fast * (lfo > 0.3)
    bass_l = np.tanh(m_filter(bass_l, "lp", cutoff, 3.2) * 1.4)
    bass_r = np.tanh(m_filter(bass_r, "lp", cutoff * 1.05, 3.2) * 1.4)
    bass_l = m_filter(bass_l, "hp", 90)
    bass_r = m_filter(bass_r, "hp", 90)
    L += bass_l * 0.22 * duck + sub * 0.3 * duck
    R += bass_r * 0.22 * duck + sub * 0.3 * duck

    # --- pad (2-bar chords, kick-ducked) ---
    for bar in range(0, bars, 2):
        _, tones = chord_at(bar)
        d = 2 * bar_len + 0.3
        for i, f in enumerate(tones):
            for det, pan in ((-0.08, -0.7), (0.08, 0.7)):
                x = m_osc(f * 2 ** (det / 12), d, "saw", mrng.random()) * m_env(d, 0.25, 0.6, 1.0, hold=d - 0.9)
                x = lowpass_sr(lowpass_sr(x, 1400), 2200)
                put(x, bar * bar_len, 0.07 if section(bar) == "break" else 0.035, pan)
    # duck pad region lightly (applied to whole mix later for glue)

    # --- rave stabs (jungle and second drop) ---
    for bar in range(bars):
        if section(bar) not in ("jungle", "drop_a2"):
            continue
        _, tones = chord_at(bar)
        for st in ((3, 11) if bar % 2 == 0 else (6,)):
            d = 0.16
            x = sum(m_osc(f / 2 * 2 ** (det / 12), d, "saw") for f in tones for det in (-0.1, 0.1))
            x = m_filter(x, "hp", 300) * m_env(d, 0.002, d, 2)
            x = m_filter(x, "lp", 3500, 1.2)
            put(x, bar * bar_len + st * STEP, 0.05, 0.25 if st == 3 else -0.25)

    # --- pluck arpeggio with a dotted-eighth echo ---
    arp_l = np.zeros(total)
    arp_r = np.zeros(total)
    for bar in range(bars):
        sec = section(bar)
        if sec == "drop_b" and bar >= 24:
            continue  # leave room for the lead
        _, tones = chord_at(bar)
        order = [0, 2, 1, 3, 2, 1, 3, 2]
        for st in range(0, 16, 2):
            f = tones[order[(st // 2) % 8]] * 2
            d = 0.14
            x = (m_osc(f, d, "square") * 0.5 + m_osc(f, d, "tri")) * m_env(d, 0.002, d, 3)
            x = lowpass_sr(x, 2600 if sec != "break" else 1500)
            s = int((bar * bar_len + st * STEP) * SR)
            e = min(total, s + len(x))
            arp_l[s:e] += x[: e - s]
            arp_r[s:e] += x[: e - s]
    echo = int(3 * STEP * SR)
    for k, (gl, gr) in enumerate(((0.0, 0.5), (0.35, 0.0), (0.0, 0.22), (0.12, 0.0))):
        sh = echo * (k + 1)
        arp_l[sh:] += arp_l[:-sh] * gl if gl else 0
        arp_r[sh:] += arp_r[:-sh] * gr if gr else 0
    brk = np.zeros(total)
    brk[int(16 * bar_len * SR):int(20 * bar_len * SR)] = 1.0
    brk = lowpass_sr(brk, 3)
    L += arp_l * (0.05 + 0.05 * brk)
    R += arp_r * (0.05 + 0.05 * brk)

    # --- lead hook (second drop): detuned saw with vibrato and echo ---
    lead = np.zeros(total)
    for rep, start_bar in enumerate((20, 24, 28)):
        if rep == 1:
            continue  # call, response by arp, call again
        for st, ln, n in LEAD:
            d = ln * STEP * 0.95
            f = nf(n)
            t = m_t(d)
            vib = 1 + 0.006 * np.sin(2 * np.pi * 5.5 * t) * np.clip(t * 4 - 0.4, 0, 1)
            x = sum(m_osc(f * vib * 2 ** (det / 12), d, "saw", mrng.random()) for det in (-0.1, 0.0, 0.1)) / 3
            x = m_filter(x, "lp", 3200, 1.0) * m_env(d, 0.01, 0.12, 1.0, hold=d - 0.13)
            s = int((start_bar * bar_len + st * STEP) * SR)
            e = min(total, s + len(x))
            lead[s:e] += x[: e - s]
    lead_echo = lead.copy()
    sh = int(3 * STEP * SR)
    lead_echo[sh:] += lead[:-sh] * 0.3
    L += lead_echo * 0.1 + np.concatenate([np.zeros(int(0.012 * SR)), lead_echo[:-int(0.012 * SR)]]) * 0.02
    R += lead_echo * 0.1

    # --- riser into the second drop ---
    d = 2 * bar_len
    rz = m_noise(d) * np.linspace(0, 1, int(d * SR)) ** 2
    rz = m_filter(rz, "bp", np.linspace(400, 7000, len(rz)), 1.5)
    put(rz, 18 * bar_len, 0.25, -0.3)
    put(rz, 18 * bar_len, 0.25, 0.3)

    # Fold the tail (echoes, crash) over the start, then glue and limit.
    n = int(bars * bar_len * SR)
    L[: total - n] += L[n:]
    R[: total - n] += R[n:]
    L, R = L[:n], R[:n]
    mix = np.stack([L, R], axis=1)
    mix = m_filter(mix[:, 0], "hp", 28)[:, None] * [1, 0] + m_filter(mix[:, 1], "hp", 28)[:, None] * [0, 1]
    peak = np.max(np.abs(mix))
    mix = np.tanh(mix / peak * 1.25) / np.tanh(1.25)
    return mix


def save_ogg_stereo(name, x, peak=0.7):
    """x: (n, 2) array at SR."""
    data = (np.clip(x, -1, 1) * peak * 32767).astype("<i2")
    tmp = os.path.join(OUT, "_tmp_" + name + ".wav")
    with wave.open(tmp, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    path = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c:a", "libvorbis", "-q:a", "4", path], check=True)
    os.remove(tmp)


def music_menu():
    """Liquid drum and bass for the menus: same tempo and key as the race
    track so the two belong together, but softer. Electric-piano chords, a
    warm sub, a gentle rolling beat and an echoing melody. 24 bars: 4 bars
    build in, 16 bars of groove, 4 bars thin out, then it loops."""
    bars = 24
    bar_len = 16 * STEP
    total = int(bars * bar_len * SR) + SR * 3
    L = np.zeros(total)
    R = np.zeros(total)
    duck = np.ones(total)
    rng2 = np.random.default_rng(96)

    def put(x, t, gain=1.0, pan=0.0):
        s_ = int(round(t * SR))
        e = min(total, s_ + len(x))
        if e <= s_:
            return
        seg = x[: e - s_] * gain
        L[s_:e] += seg * np.sqrt(0.5 * (1 - pan))
        R[s_:e] += seg * np.sqrt(0.5 * (1 + pan))

    def stage(bar):
        if bar < 4:
            return "intro"
        if bar < 20:
            return "groove"
        return "outro"

    kick = lowpass_sr(d_kick(), 2500)
    snare = roomify(lowpass_sr(d_snare(200, 0.8), 5000), 0.3)
    ghost = lowpass_sr(d_snare(220, 0.7), 2500)
    hat = d_hat()
    ride = d_ride()

    # --- drums ---
    for bar in range(bars):
        st_ = stage(bar)
        t0 = bar * bar_len
        for k in range(16):
            sw = STEP * 0.14 if k % 2 else 0.0
            g = (0.16 if k % 4 == 2 else 0.07) * rng2.uniform(0.8, 1.1)
            if st_ == "intro" and bar < 2 and k % 4 != 2:
                continue
            put(hat, t0 + k * STEP + sw, g, 0.4)
        if st_ == "intro":
            if bar == 3:
                for k in range(8, 16):
                    put(ghost, t0 + k * STEP, 0.08 + 0.3 * (k - 8) / 8)
            continue
        kicks = [(0, 1.0), (10, 0.85)] if bar % 2 == 0 else [(0, 1.0), (7, 0.5), (10, 0.85)]
        snrs = [(4, 1.0), (12, 1.0)]
        ghosts = [(7, 0.25), (9, 0.2), (15, 0.3)] if bar % 2 else [(6, 0.2), (14, 0.25)]
        if st_ == "outro":
            kicks = kicks if bar < 22 else [(0, 0.8)]
            ghosts = ghosts if bar < 22 else []
        for k, g in kicks:
            put(kick, t0 + k * STEP, 0.75 * g)
            s_ = int((t0 + k * STEP) * SR)
            dl = int(0.2 * SR)
            e = min(total, s_ + dl)
            duck[s_:e] = np.minimum(duck[s_:e], 1 - 0.4 * g * np.linspace(1, 0, dl)[: e - s_] ** 1.5)
        for k, g in snrs:
            put(snare, t0 + k * STEP, 0.5 * g)
        for k, g in ghosts:
            put(ghost, t0 + k * STEP + 0.006, 0.5 * g, rng2.uniform(-0.2, 0.2))
        for q in range(4):
            put(ride, t0 + q * 4 * STEP + 2 * STEP, 0.06, -0.45)

    # --- electric piano: a sine with a soft bell partial, syncopated ---
    def epiano(f, d):
        t = m_t(d)
        mod = np.sin(2 * np.pi * f * 2 * t) * 1.2 * np.exp(-t * 6)
        x = np.sin(2 * np.pi * f * t + mod) + 0.25 * np.sin(2 * np.pi * f * 3 * t) * np.exp(-t * 9)
        trem = 1 + 0.12 * np.sin(2 * np.pi * 4.5 * t)
        return x * trem * m_env(d, 0.004, d, 1.6)

    for bar in range(bars):
        _, tones = chord_at(bar)
        hits = [(0, 6), (6, 4), (10, 6)] if bar % 2 == 0 else [(0, 7), (11, 5)]
        g_bar = 1.0
        for k, ln in hits:
            d = ln * STEP + 0.35
            for i, f in enumerate(tones):
                put(epiano(f / 2, d), bar * bar_len + k * STEP + i * 0.008, 0.06 * g_bar, -0.3 + 0.2 * i)

    # --- pad ---
    for bar in range(0, bars, 2):
        _, tones = chord_at(bar)
        d = 2 * bar_len + 0.5
        for f in tones:
            for det, pan in ((-0.1, -0.8), (0.1, 0.8)):
                x = m_osc(f * 2 ** (det / 12), d, "saw", rng2.random()) * m_env(d, 0.6, 0.8, 1.0, hold=d - 1.4)
                x = lowpass_sr(lowpass_sr(x, 900), 1600)
                put(x, bar * bar_len, 0.03, pan)

    # --- warm sub and a soft, slowly filtered bass ---
    sub = np.zeros(total)
    mid = np.zeros(total)
    for bar in range(bars):
        root, _ = chord_at(bar)
        notes = [(0, 12, 0), (12, 4, 7)] if bar % 2 == 0 else [(0, 8, 0), (8, 4, 12), (12, 4, 10)]
        if stage(bar) == "outro" and bar >= 22:
            notes = [(0, 16, 0)]
        for k, ln, semi in notes:
            f = root * 2 ** (semi / 12)
            d = ln * STEP * 0.97
            e = m_env(d, 0.01, 0.05, 1.0, hold=d - 0.07)
            s_ = int((bar * bar_len + k * STEP) * SR)
            x = m_osc(f, d) * e
            ee = min(total, s_ + len(x))
            sub[s_:ee] += x[: ee - s_]
            y = (m_osc(f * 2 ** (0.1 / 12), d, "saw") + m_osc(f * 2 ** (-0.1 / 12), d, "saw")) * e
            mid[s_:ee] += y[: ee - s_]
    tt = np.arange(total) / SR
    cutoff = 260 + 260 * (0.5 - 0.5 * np.cos(2 * np.pi * tt / (4 * bar_len)))
    mid = m_filter(m_filter(mid, "lp", cutoff, 1.4), "hp", 100)
    L += (sub * 0.32 + mid * 0.07) * duck
    R += (sub * 0.32 + mid * 0.07) * duck

    # --- melody: a slow, echoing pluck over the groove ---
    MEL = [(0, 4, "C6"), (6, 2, "D#6"), (8, 8, "F6"), (16, 4, "D#6"), (22, 2, "C6"), (24, 8, "G#5"),
           (32, 4, "C6"), (38, 2, "C#6"), (40, 8, "C6"), (48, 4, "A#5"), (54, 2, "G5"), (56, 8, "G5")]
    mel = np.zeros(total)
    for start_bar in (8, 16):
        for k, ln, n in MEL:
            d = ln * STEP + 0.3
            f = nf(n)
            x = (m_osc(f, d, "tri") + 0.3 * m_osc(f * 2, d)) * m_env(d, 0.006, d, 2.0)
            x = lowpass_sr(x, 3000)
            s_ = int((start_bar * bar_len + k * STEP) * SR)
            mel[s_:s_ + len(x)] += x
    # Ping-pong dotted-eighth delay: each repeat bounces sides, gets quieter
    # and darker. The melody ends at bar 20; the 14 repeats are below -45 dB
    # by bar 23, and anything left over folds smoothly into the loop start.
    echo = int(3 * STEP * SR)
    ml = mel.copy()
    mr = mel.copy()
    tap = mel.copy()
    for k_ in range(14):
        tap = lowpass_sr(tap, 2800 - 120 * k_) * (0.72 if k_ == 0 else 0.68)
        sh = echo * (k_ + 1)
        side = ml if k_ % 2 else mr
        side[sh:] += tap[:-sh]
    # Reverb: a soft 2 s stereo room behind the echoes. It starts 60 ms
    # late and swells in over 120 ms, so it doesn't smear the note attacks.
    from scipy.signal import fftconvolve
    rlen = int(2.2 * SR)
    t = np.arange(rlen) / SR
    decay = np.exp(-t * 6.9 / 2.0)               # about -60 dB at 2 s
    decay *= np.clip((t - 0.06) / 0.12, 0.0, 1.0) ** 2
    wet = []
    for side in (ml, mr):
        ir = rng2.standard_normal(rlen) * decay
        ir = lowpass_sr(ir, 4500) * 0.6 + lowpass_sr(ir, 1500) * 0.4
        ir /= np.sqrt((ir ** 2).sum())
        wet.append(fftconvolve(side, ir)[:total])
    L += ml * 0.07 + wet[0] * 0.028
    R += mr * 0.07 + wet[1] * 0.028

    # --- a soft air/vinyl bed ---
    air = m_filter(m_noise(total / SR), "bp", 5000, 0.5)
    crackle = np.zeros(total)
    idx = rng2.integers(0, total, int(total / SR * 6))
    crackle[idx] = rng2.uniform(-1, 1, len(idx))
    L += air * 0.004 + lowpass_sr(crackle, 6000) * 0.05
    R += air[::-1] * 0.004 + lowpass_sr(np.roll(crackle, 777), 6000) * 0.05

    n = int(bars * bar_len * SR)
    L[: total - n] += L[n:]
    R[: total - n] += R[n:]
    mix = np.stack([m_filter(L[:n], "hp", 28), m_filter(R[:n], "hp", 28)], axis=1)
    peak = np.max(np.abs(mix))
    return np.tanh(mix / peak * 1.15) / np.tanh(1.15)


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
    save_ogg_stereo("music_race", music_race())
    print("wrote music_race.ogg")
    save_ogg_stereo("music_menu", music_menu(), 0.52)
    print("wrote music_menu.ogg")


if __name__ == "__main__":
    main()
