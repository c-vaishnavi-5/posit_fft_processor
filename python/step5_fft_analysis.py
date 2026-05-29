# ═══════════════════════════════════════════════════════════════════════
# step5_fft_analysis.py
# ═══════════════════════════════════════════════════════════════════════
#
# PURPOSE:
#   Takes the 8-point FFT output from the FPGA and performs
#   intelligent audio analysis using ONLY the 8 frequency bins.
#
# DATA SOURCE:
#   This script reads EXCLUSIVELY from the FPGA pipeline outputs:
#     - fft_results.npy  (from step4_uart_rx.py) -> Xr, Xi, sample_rate
#     - samples_fp64.npy (from step1_audio_extract.py) -> 8 time-domain samples
#   No hardcoded WAV files or synthetic signals are used.
#
# FEATURES IMPLEMENTED:
#   1. Spectrum Analysis     - magnitude, dominant bin, energy per bin
#   2. Frequency Band Energy - low/mid/high band decomposition
#   3. Voice Classification  - calm / energetic / noisy
#   4. Emotion Hints         - calm / happy / angry / sad
#   5. Calmness Score        - overall score out of 10
#   6. Posit vs NumPy        - accuracy comparison (FPGA posit vs float64)
#
# HOW IT WORKS:
#   The FPGA computes an 8-point FFT on 8 audio samples.
#   This gives us 8 complex numbers (Xr + jXi) representing
#   the frequency content of that audio chunk.
#
#   From these 8 values we compute magnitudes:
#       |X[k]| = sqrt(Xr[k]^2 + Xi[k]^2)
#
#   The 8 bins map to frequencies:
#       Bin k  -->  frequency = k * (sample_rate / 8)
#
#   For a REAL signal, bins 5-7 are mirrors of bins 3-1:
#       |X[7]| = |X[1]|,  |X[6]| = |X[2]|,  |X[5]| = |X[3]|
#   So the unique information is in bins 0-4 only.
#
# PIPELINE:
#   step1 -> step2 -> step3 (UART TX) -> FPGA -> step4 (UART RX) -> step5
#
# USAGE:
#   python step5_fft_analysis.py
# ═══════════════════════════════════════════════════════════════════════

import os
import numpy as np
from datetime import datetime
import matplotlib
matplotlib.use('Agg')   # Use non-interactive backend so plots save to files
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec


# ─── Configuration ────────────────────────────────────────────────────
RESULTS_FILE = 'fft_results.npy'    # FFT output from step4 (FPGA)
SAMPLES_FILE = 'samples_fp64.npy'   # Original 8 samples from step1
SAVE_PLOTS   = True
N_FFT        = 32                    # 32-point FFT (adapted for new FPGA design)

# ─── Dark Theme Colors ───────────────────────────────────────────────
#   These hex colors create a professional dark-mode look for all plots.
C_BG    = '#0D1117'    # background (very dark blue-black)
C_PANEL = '#161B22'    # panel/axes background
C_TEXT  = '#E6EDF3'    # main text color (off-white)
C_MUTED = '#8B949E'    # secondary text (grey)
C_EDGE  = '#30363D'    # borders and grid lines
C_BLUE  = '#2196F3'    # primary accent
C_ORANGE= '#FF5722'    # warm accent
C_GREEN = '#4CAF50'    # positive/calm
C_GOLD  = '#FFC107'    # highlight/dominant
C_RED   = '#F44336'    # negative/harsh
C_CYAN  = '#00BCD4'    # cool accent
C_PURPLE= '#9C27B0'    # secondary accent

# Apply dark theme to all matplotlib plots globally
plt.rcParams.update({
    'font.family': 'monospace',
    'figure.facecolor': C_BG,   'axes.facecolor': C_PANEL,
    'axes.labelcolor': C_TEXT,  'xtick.color': C_MUTED,
    'ytick.color': C_MUTED,    'text.color': C_TEXT,
    'axes.edgecolor': C_EDGE,  'grid.color': C_EDGE,
    'axes.titlecolor': C_TEXT,  'axes.spines.top': False,
    'axes.spines.right': False,
})


# ═══════════════════════════════════════════════════════════════════════
# SECTION 1: AUDIO LOADING
# ═══════════════════════════════════════════════════════════════════════
# These functions load audio from WAV files and extract 8 samples
# for FFT processing.

def load_wav(path):
    """
    Load a WAV file and normalize it to [-1, 1] range.

    Steps:
      1. Read raw samples using scipy.io.wavfile
      2. Convert to float64 for precision
      3. If stereo (2 channels), average to mono
      4. Divide by peak value so range becomes [-1, 1]

    Returns: (signal_array, sample_rate_hz)
    """
    rate, data = wavfile.read(path)
    data = data.astype(np.float64)
    if data.ndim == 2:
        data = np.mean(data, axis=1)       # stereo -> mono
    peak = np.max(np.abs(data))
    if peak > 0:
        data = data / peak                  # normalize to [-1, 1]
    return data, rate


def extract_frame(signal, rate, N=8):
    """
    Extract N samples aligned to a rising zero-crossing near the center.

    WHY: For consistent FFT results, we want the 8-sample window to
    start at a reproducible point in the waveform. A rising zero-crossing
    (where signal goes from negative to positive) gives us this.

    Steps:
      1. Look at signal around the midpoint
      2. Scan for where signal[i-1] < 0 and signal[i] >= 0
      3. Take 8 samples starting one sample before that crossing
      4. Remove DC offset (subtract mean)

    Returns: array of N float64 samples
    """
    mid = len(signal) // 2
    sr = min(rate, mid - N)
    win = signal[mid - sr : mid + sr]

    start = None
    for i in range(1, len(win) - N):
        if win[i-1] < 0 and win[i] >= 0:   # rising zero-crossing found
            a = (mid - sr) + i - 1
            if a >= 0 and a + N <= len(signal):
                start = a
                break
    if start is None:
        start = mid                          # fallback: use center

    frame = signal[start:start+N].copy()
    return frame - np.mean(frame)            # remove DC offset


# ═══════════════════════════════════════════════════════════════════════
# SECTION 2: SPECTRUM ANALYSIS  (Feature Category 1)
# ═══════════════════════════════════════════════════════════════════════
# This is the most basic analysis: look at the 8 FFT magnitudes and
# find which frequency bin has the most energy.
#
# MATH:
#   magnitude[k] = sqrt(Xr[k]^2 + Xi[k]^2)    for k = 0,1,...,7
#   phase[k]     = arctan2(Xi[k], Xr[k])       in degrees
#   energy[k]    = magnitude[k]^2               (power in that bin)
#
# The "dominant bin" is the bin with the highest magnitude,
# searching only bins 1 through N/2 (we skip bin 0 = DC component,
# and bins 5-7 which are just mirrors for real signals).

def analyze_spectrum(Xr, Xi):
    """
    Analyze the 8 FFT complex outputs.

    Inputs:
      Xr: array of 8 real parts from FFT
      Xi: array of 8 imaginary parts from FFT

    Returns dict with:
      magnitudes   - |X[k]| for each bin
      dominant_bin - which bin (1-4) has the peak
      dominant_hz  - peak frequency in Hz
      energy       - |X[k]|^2 for each bin
      phase_deg    - phase angle in degrees
    """
    # Compute magnitude: |X[k]| = sqrt(real^2 + imag^2)
    mags = np.sqrt(Xr**2 + Xi**2)

    # Search bins 1 to N/2 for the dominant frequency
    # (skip bin 0 = DC, skip bins 5-7 = mirrors)
    search_range = mags[1 : N_FFT//2 + 1]   # bins 1,2,3,4
    dom_bin = int(np.argmax(search_range)) + 1

    # Phase: angle of each complex number in degrees
    phase = np.degrees(np.arctan2(Xi, Xr))

    return dict(
        magnitudes = mags,
        dominant_bin = dom_bin,
        energy = mags**2,
        phase_deg = phase,
        Xr = Xr,
        Xi = Xi,
    )


# ═══════════════════════════════════════════════════════════════════════
# SECTION 3: FREQUENCY BAND ENERGY  (Feature Category 2)
# ═══════════════════════════════════════════════════════════════════════
# Since we only have 8 bins (very coarse resolution), we compensate
# by grouping bins into 3 frequency bands:
#
#   LOW  = bins 0-4  (DC to ~0.15Fs)  -- bass / depth
#   MID  = bins 5-11 (~0.15 to ~0.35Fs)-- voice / clarity
#   HIGH = bins 12-16(~0.35Fs to Nyquist)- sharpness / noise
#
# We use ONLY the unique half of the spectrum (bins 0-16 for N=32).
# Bins 17-31 are mirrors and would double-count energy.
#
# "Energy" = sum of magnitude^2 in each band.
# Percentages show how the total energy is distributed.

def analyze_bands(mags):
    """
    Split the 32-bin spectrum into Low/Mid/High bands.

    Input: magnitudes array (8 values)
    Returns dict with energy and percentage for each band.
    """
    # Only use unique bins (0 to N/2)
    half = N_FFT // 2 + 1         # = 17 bins: indices 0..16

    # Sum squared magnitudes in each band
    low  = np.sum(mags[0:5]**2)   # bins 0-4
    mid  = np.sum(mags[5:12]**2)  # bins 5-11
    high = np.sum(mags[12:half]**2) # bins 12-16
    total = low + mid + high + 1e-12   # add tiny value to avoid /0

    # Which band has the most energy?
    if low >= mid and low >= high:
        dom_band = 'Low'
    elif mid >= high:
        dom_band = 'Mid'
    else:
        dom_band = 'High'

    return dict(
        low_e=low,  mid_e=mid,  high_e=high,  total_e=total,
        low_pct  = low/total*100,
        mid_pct  = mid/total*100,
        high_pct = high/total*100,
        dominant_band = dom_band,
    )


# ═══════════════════════════════════════════════════════════════════════
# SECTION 4: VOICE CLASSIFICATION  (Feature Category 3)
# ═══════════════════════════════════════════════════════════════════════
# Using ONLY the band energy percentages and the flatness of the
# spectrum, we classify the signal into one of three types:
#
#   CALM      - energy concentrated in low band, not flat spectrum
#   ENERGETIC - energy spread across bands, moderate flatness
#   NOISY     - nearly flat spectrum (all bins have similar energy)
#
# "Spectral flatness" measures how uniform the bin magnitudes are:
#   flatness = geometric_mean(mags) / arithmetic_mean(mags)
#   Range: 0 (one bin dominates) to 1 (all bins equal = noise)
#
# The classification uses a scoring system where each feature
# adds points to the matching category. Highest score wins.

def compute_flatness(mags):
    """
    Spectral flatness: ratio of geometric mean to arithmetic mean.

    For a pure tone: one bin is large, rest ~0 -> flatness near 0
    For white noise: all bins similar -> flatness near 1

    We use bins 1-4 (skip DC which is always ~0 after DC removal).
    """
    m = mags[1 : N_FFT//2 + 1]          # bins 1,2,3,4
    m = np.maximum(m, 1e-12)             # avoid log(0)
    geo_mean = np.exp(np.mean(np.log(m))) # geometric mean
    ari_mean = np.mean(m)                 # arithmetic mean
    return geo_mean / (ari_mean + 1e-12)  # 0=tonal, 1=noisy


def classify_voice(bands, flatness):
    """
    Classify signal as Calm, Energetic, or Noisy.

    Logic (scoring system):
      CALM:      low_pct > 60% (+30), flatness < 0.3 (+30), low_pct > 40% (+20)
      ENERGETIC: 20% < low_pct < 70% (+25), 0.2 < flatness < 0.7 (+25),
                 mid_pct > 15% (+25)
      NOISY:     flatness > 0.6 (+35), flatness > 0.8 (+25),
                 high_pct > 15% (+20)
    """
    lp = bands['low_pct']
    mp = bands['mid_pct']
    hp = bands['high_pct']

    calm = 0; ener = 0; noisy = 0

    # --- Calm indicators ---
    if lp > 60:   calm += 30    # energy concentrated in bass
    if lp > 40:   calm += 20    # moderate bass presence
    if flatness < 0.3: calm += 30   # spectrum is peaky (tonal)

    # --- Energetic indicators ---
    if 20 < lp < 70:    ener += 25  # energy spread, not all in one band
    if 0.2 < flatness < 0.7: ener += 25  # moderate flatness
    if mp > 15:          ener += 25  # mid-band activity (voice range)

    # --- Noisy indicators ---
    if flatness > 0.6:  noisy += 35  # flat spectrum = noise-like
    if flatness > 0.8:  noisy += 25  # very flat = definitely noise
    if hp > 15:         noisy += 20  # high-freq energy = harsh

    total = calm + ener + noisy + 1e-12
    scores = {
        'Calm':      calm / total * 100,
        'Energetic': ener / total * 100,
        'Noisy':     noisy / total * 100,
    }
    voice_type = max(scores, key=scores.get)

    return dict(voice_type=voice_type, confidence=scores[voice_type], scores=scores)


# ═══════════════════════════════════════════════════════════════════════
# SECTION 5: EMOTION HINTS  (Feature Category 4)
# ═══════════════════════════════════════════════════════════════════════
# Maps the FFT-derived features to basic emotional categories.
# This is a COARSE estimate since we only have 8 frequency bins.
#
# The mapping logic:
#   CALM:  low-band dominant + spectrum peaky (tonal)
#   HAPPY: energy in mid band + moderate spread
#   ANGRY: flat spectrum (noisy) + high-band energy
#   SAD:   very low-band dominant + very peaky spectrum

def detect_emotion(bands, flatness):
    """
    Estimate emotional tone from spectrum shape.

    Returns the dominant emotion with confidence percentage.
    """
    lp = bands['low_pct']
    mp = bands['mid_pct']
    hp = bands['high_pct']

    calm = 0; happy = 0; angry = 0; sad = 0

    # --- Calm: tonal, bass-heavy ---
    if lp > 50:          calm += 30
    if flatness < 0.3:   calm += 30
    if hp < 10:          calm += 20

    # --- Happy: mid-range energy, moderate variety ---
    if mp > 20:          happy += 30
    if 0.2 < flatness < 0.6: happy += 30
    if lp > 30:          happy += 20

    # --- Angry: flat/noisy, high-band energy ---
    if flatness > 0.5:   angry += 30
    if hp > 15:          angry += 30
    if flatness > 0.7:   angry += 20

    # --- Sad: very bass-heavy, very tonal ---
    if lp > 70:          sad += 35
    if flatness < 0.2:   sad += 30
    if hp < 5:           sad += 15

    total = calm + happy + angry + sad + 1e-12
    scores = {
        'Calm':  calm/total*100,  'Happy': happy/total*100,
        'Angry': angry/total*100, 'Sad':   sad/total*100,
    }
    emotion = max(scores, key=scores.get)

    return dict(emotion=emotion, confidence=scores[emotion], scores=scores)


# ═══════════════════════════════════════════════════════════════════════
# SECTION 6: SIMILARITY ANALYSIS  (Feature Category 5)
# ═══════════════════════════════════════════════════════════════════════
# Compares two signals by looking at how similar their FFT magnitude
# patterns are. Uses cosine similarity:
#
#   similarity = (A . B) / (|A| * |B|)
#
# where A and B are the magnitude vectors from two signals.
# Result: 1.0 = identical shape, 0.0 = completely different.
#
# We also compare band energy ratios as a second measure.

def cosine_sim(a, b):
    """
    Cosine similarity between two vectors.
    Returns value between -1 and 1 (usually 0 to 1 for magnitudes).
    """
    dot = np.dot(a, b)
    norm = np.linalg.norm(a) * np.linalg.norm(b)
    return float(dot / norm) if norm > 1e-12 else 0.0


def analyze_similarity(res_a, res_b):
    """
    Compare two analysis results.

    Two measures:
      1. Magnitude pattern: cosine similarity of 8-bin magnitudes
      2. Band pattern: cosine similarity of [low%, mid%, high%]
    """
    # Compare full 8-bin magnitude shapes
    mag_sim = cosine_sim(res_a['spec']['magnitudes'],
                         res_b['spec']['magnitudes'])

    # Compare band energy distributions
    ba = res_a['bands']; bb = res_b['bands']
    va = np.array([ba['low_pct'], ba['mid_pct'], ba['high_pct']])
    vb = np.array([bb['low_pct'], bb['mid_pct'], bb['high_pct']])
    band_sim = cosine_sim(va, vb)

    avg = (mag_sim + band_sim) / 2 * 100
    match = 'Close' if avg > 80 else ('Moderate' if avg > 50 else 'Far')

    return dict(mag_sim=mag_sim*100, band_sim=band_sim*100,
                avg_sim=avg, match=match)


# ═══════════════════════════════════════════════════════════════════════
# SECTION 7: CALMNESS SCORE  (Feature Category 6 — MAIN FEATURE)
# ═══════════════════════════════════════════════════════════════════════
# The calmness score combines multiple indicators into a single
# number from 0 to 10:
#
#   CALMNESS (higher = more pleasant):
#     +  High low-band ratio     (bass = warm/calm)
#     +  Low spectral flatness   (tonal = pleasant)
#     +  Low high-band ratio     (no harshness)
#     +  High magnitude concentration (clear tone)
#
#   HARSHNESS (higher = more harsh):
#     +  High spectral flatness  (noisy)
#     +  High high-band ratio    (sharp/piercing)
#     +  Low concentration       (diffuse energy)
#
# "Concentration" measures how much energy is in the dominant bin
# relative to total energy. High concentration = pure tone.

def compute_calmness(bands, flatness, mags):
    """
    Compute calmness, stability, and harshness scores (each 0-10).
    """
    lp = bands['low_pct'] / 100.0        # 0-1, higher = more bass
    hp = bands['high_pct'] / 100.0       # 0-1, higher = harsher
    flat = min(flatness, 1.0)            # 0-1, higher = noisier

    # Concentration: what fraction of energy is in the peak bin?
    # For a pure sine wave this is ~1.0, for noise ~0.25
    unique_mags = mags[1 : N_FFT//2 + 1]  # bins 1-4
    total_mag = np.sum(unique_mags) + 1e-12
    concentration = np.max(unique_mags) / total_mag  # 0.25 to 1.0

    # CALMNESS: weighted sum of "calm" indicators, scaled to 0-10
    #   lp contributes positively (bass = calm)
    #   flat contributes negatively (noise = not calm)
    #   hp contributes negatively (harshness = not calm)
    #   concentration contributes positively (tonal = calm)
    calmness = (
        0.30 * lp +                  # more bass energy = calmer
        0.25 * (1.0 - flat) +        # less flat (more tonal) = calmer
        0.25 * (1.0 - hp) +          # less high-freq = calmer
        0.20 * concentration          # more concentrated = calmer
    ) * 10.0
    calmness = max(0, min(10, calmness))

    # HARSHNESS: opposite of calmness indicators
    harshness = (
        0.35 * flat +                # flatter spectrum = harsher
        0.35 * hp +                  # more high-freq = harsher
        0.30 * (1.0 - concentration) # more diffuse = harsher
    ) * 10.0
    harshness = max(0, min(10, harshness))

    # STABILITY: based on how concentrated the energy is
    # (pure tone = very stable, noise = unstable)
    stability = (0.6 * concentration + 0.4 * (1.0 - flat)) * 10.0
    stability = max(0, min(10, stability))

    return dict(calmness=calmness, stability=stability, harshness=harshness)


# ═══════════════════════════════════════════════════════════════════════
# SECTION 8: FULL ANALYSIS PIPELINE
# ═══════════════════════════════════════════════════════════════════════
# This function runs ALL analyses on a single signal and returns
# a dictionary containing every computed feature.

def analyze_signal(name, signal, sr, Xr=None, Xi=None):
    """
    Run the complete analysis pipeline on one signal.

    If Xr/Xi are provided (from FPGA), use those.
    Otherwise, compute 8-point FFT in Python (simulates FPGA).
    """
    # Step 1: Get 8 samples aligned to zero-crossing
    frame = extract_frame(signal, sr, N_FFT)

    # Step 2: If no FPGA FFT provided, compute it in Python
    if Xr is None:
        fft_out = np.fft.fft(frame)
        Xr = fft_out.real
        Xi = fft_out.imag

    # Step 3: Run all analysis categories
    spec     = analyze_spectrum(Xr, Xi)
    bands    = analyze_bands(spec['magnitudes'])
    flatness = compute_flatness(spec['magnitudes'])
    voice    = classify_voice(bands, flatness)
    emotion  = detect_emotion(bands, flatness)
    calmness = compute_calmness(bands, flatness, spec['magnitudes'])

    # Add derived info
    bin_res = sr / N_FFT
    spec['bin_res']     = bin_res
    spec['dominant_hz'] = spec['dominant_bin'] * bin_res
    spec['freqs']       = np.arange(N_FFT) * bin_res

    return dict(name=name, sr=sr, frame=frame, spec=spec, bands=bands,
                flatness=flatness, voice=voice, emotion=emotion,
                calmness=calmness)


# ═══════════════════════════════════════════════════════════════════════
# SECTION 9: CONSOLE REPORT
# ═══════════════════════════════════════════════════════════════════════

def print_report(r):
    """Print a detailed text report for one analyzed signal."""
    w = 70
    s = r['spec']; b = r['bands']; v = r['voice']
    e = r['emotion']; c = r['calmness']
    br = s['bin_res']

    print('\n' + '='*w)
    print(f"  COMPREHENSIVE ANALYSIS: {r['name']}")
    print(f"  Sample Rate: {r['sr']} Hz | FFT Size: {N_FFT}")
    print(f"  Bin Resolution: {br:.2f} Hz/bin")
    print('='*w)

    # 1. Spectrum
    print(f"\n--- 1. SPECTRUM ANALYSIS (32-Point FFT) ---")
    print(f"  Dominant Bin: {s['dominant_bin']} ({s['dominant_hz']:.2f} Hz)")
    print(f"  {'Bin':<5} {'Freq(Hz)':<10} {'Magnitude':<14} {'Energy':<14} {'Phase(deg)'}")
    print(f"  {'-'*58}")
    for k in range(N_FFT):
        mk = '*' if k == s['dominant_bin'] else ' '
        print(f" {mk}{k:<4} {s['freqs'][k]:<10.1f} {s['magnitudes'][k]:<14.6f} "
              f"{s['energy'][k]:<14.6f} {s['phase_deg'][k]:.1f}")

    # 2. Band Energy
    print(f"\n--- 2. FREQUENCY BAND ENERGY ---")
    print(f"  Low  (bins 0-4) : {b['low_e']:.6f}  ({b['low_pct']:.1f}%)")
    print(f"  Mid  (bins 5-11): {b['mid_e']:.6f}  ({b['mid_pct']:.1f}%)")
    print(f"  High (bins 12-16): {b['high_e']:.6f}  ({b['high_pct']:.1f}%)")
    print(f"  Dominant Band   : {b['dominant_band']}")
    print(f"  Spectral Flatness: {r['flatness']:.4f}  "
          f"({'Tonal' if r['flatness']<0.3 else 'Mixed' if r['flatness']<0.6 else 'Noisy'})")

    # 3. Voice Classification
    print(f"\n--- 3. VOICE CLASSIFICATION ---")
    print(f"  Voice Type: {v['voice_type']}  (confidence: {v['confidence']:.1f}%)")
    for k, val in v['scores'].items():
        bar = '#' * int(val / 5)
        print(f"    {k:<10}: {val:5.1f}% |{bar}")

    # 4. Emotion
    print(f"\n--- 4. EMOTION HINTS ---")
    print(f"  Emotion: {e['emotion']}  (confidence: {e['confidence']:.1f}%)")
    for k, val in e['scores'].items():
        bar = '#' * int(val / 5)
        print(f"    {k:<10}: {val:5.1f}% |{bar}")

    # 5. Calmness Score
    def bar10(v): return '#' * int(v) + '.' * (10 - int(v))
    print(f"\n--- 6. CALMNESS SCORE (MAIN FEATURE) ---")
    print(f"  Calmness  [{bar10(c['calmness'])}] {c['calmness']:.1f}/10")
    print(f"  Stability [{bar10(c['stability'])}] {c['stability']:.1f}/10")
    print(f"  Harshness [{bar10(c['harshness'])}] {c['harshness']:.1f}/10")
    print('='*w)


# ═══════════════════════════════════════════════════════════════════════
# SECTION 10: DASHBOARD PLOTTING
# ═══════════════════════════════════════════════════════════════════════

def plot_dashboard(r, idx=0):
    """Create a 2x3 visual dashboard for one analyzed signal."""
    fig = plt.figure(figsize=(16, 9))
    fig.suptitle(f'Audio Analysis Dashboard: {r["name"]}',
                 fontsize=14, fontweight='bold', y=0.98)
    gs = gridspec.GridSpec(2, 3, figure=fig, hspace=0.4, wspace=0.35)
    s = r['spec']; b = r['bands']; v = r['voice']
    e = r['emotion']; c = r['calmness']

    # ── Panel 1: Magnitude Spectrum (bar chart of 32 bins) ──
    ax = fig.add_subplot(gs[0, 0])
    colors = [C_GOLD if k == s['dominant_bin'] else C_BLUE for k in range(N_FFT)]
    ax.bar(s['freqs'], s['magnitudes'], width=s['bin_res']*0.8,
           color=colors, edgecolor=C_EDGE, linewidth=0.8, zorder=3)
    for k in range(N_FFT):
        if s['magnitudes'][k] > 0.01:
            ax.text(s['freqs'][k], s['magnitudes'][k] + max(s['magnitudes'])*0.03,
                    f'{s["magnitudes"][k]:.3f}', ha='center', fontsize=7, color=C_MUTED)
    ax.set_title(f'1. Magnitude Spectrum | Dom: Bin {s["dominant_bin"]} '
                 f'({s["dominant_hz"]:.0f} Hz)', fontsize=9)
    ax.set_xlabel('Freq (Hz)', fontsize=8)
    ax.set_ylabel('Magnitude', fontsize=8)
    ax.grid(axis='y', alpha=0.3, zorder=0)

    # ── Panel 2: Band Energy (horizontal bars) ──
    ax = fig.add_subplot(gs[0, 1])
    bnames = ['Low\nbins 0-4', 'Mid\nbins 5-11', 'High\nbins 12-16']
    bvals = [b['low_pct'], b['mid_pct'], b['high_pct']]
    bcols = [C_BLUE, C_GREEN, C_ORANGE]
    bars = ax.barh(bnames, bvals, color=bcols, edgecolor=C_EDGE, height=0.5, zorder=3)
    for bar, val in zip(bars, bvals):
        ax.text(bar.get_width()+1, bar.get_y()+bar.get_height()/2,
                f'{val:.1f}%', va='center', fontsize=9, color=C_TEXT)
    ax.set_title(f'2. Band Energy ({b["dominant_band"]}-dominant) | '
                 f'Flatness={r["flatness"]:.2f}', fontsize=9)
    ax.set_xlabel('%', fontsize=8)
    ax.set_xlim(0, 115)
    ax.grid(axis='x', alpha=0.3, zorder=0)

    # ── Panel 3: Voice + Emotion Classification ──
    ax = fig.add_subplot(gs[0, 2])
    txt = (f"Voice: {v['voice_type']}\n({v['confidence']:.0f}% conf)\n\n"
           f"Emotion: {e['emotion']}\n({e['confidence']:.0f}% conf)")
    vcol = C_GREEN if v['voice_type']=='Calm' else C_BLUE if v['voice_type']=='Energetic' else C_RED
    ax.text(0.5, 0.5, txt, ha='center', va='center', fontsize=13,
            fontweight='bold', color=vcol,
            bbox=dict(boxstyle='round,pad=0.8', facecolor=C_PANEL,
                      edgecolor=vcol, alpha=0.9),
            transform=ax.transAxes)
    ax.set_title('3+4. Classification & Emotion', fontsize=9)
    ax.axis('off')

    # ── Panel 4: Calmness Gauge (horizontal bar meters) ──
    ax = fig.add_subplot(gs[1, 0:2])
    metrics = ['Calmness', 'Stability', 'Harshness']
    mvals = [c['calmness'], c['stability'], c['harshness']]
    mcols = [C_GREEN, C_BLUE, C_RED]
    y = np.arange(3)
    ax.barh(y, [10]*3, color=C_EDGE, height=0.5, zorder=1)
    for i in range(3):
        ax.barh(y[i], mvals[i], color=mcols[i], height=0.5,
                zorder=3, edgecolor=C_EDGE)
        ax.text(mvals[i]+0.2, y[i], f'{mvals[i]:.1f}/10', va='center',
                fontsize=11, fontweight='bold', color=mcols[i])
    ax.set_yticks(y)
    ax.set_yticklabels(metrics, fontsize=11)
    ax.set_xlim(0, 12)
    ax.set_title('6. CALMNESS SCORE (Main Feature)', fontsize=11, fontweight='bold')
    ax.grid(axis='x', alpha=0.2, zorder=0)

    # ── Panel 5: All Classification Scores (grouped) ──
    ax = fig.add_subplot(gs[1, 2])

    # Build grouped data: Voice scores then Emotion scores
    voice_items  = list(v['scores'].items())   # Calm, Energetic, Noisy
    emot_items   = list(e['scores'].items())   # Calm, Happy, Angry, Sad

    # Labels with group prefixes to avoid duplicates and add clarity
    labels = []
    vals_s = []
    cols_s = []
    voice_colors = {'Calm': C_GREEN, 'Energetic': C_BLUE, 'Noisy': C_RED}
    emot_colors  = {'Calm': C_GREEN, 'Happy': C_GOLD, 'Angry': C_RED, 'Sad': C_PURPLE}

    # Emotion first (top of chart), then Voice (bottom)
    for name, val in reversed(emot_items):
        labels.append(f'E: {name}')
        vals_s.append(val)
        cols_s.append(emot_colors.get(name, C_MUTED))
    labels.append('')  # spacer
    vals_s.append(0)
    cols_s.append(C_PANEL)
    for name, val in reversed(voice_items):
        labels.append(f'V: {name}')
        vals_s.append(val)
        cols_s.append(voice_colors.get(name, C_MUTED))

    y_pos = np.arange(len(labels))
    bars = ax.barh(y_pos, vals_s, color=cols_s, edgecolor=C_EDGE,
                   height=0.55, zorder=3)

    # Add percentage text — only for non-zero values
    for i, val in enumerate(vals_s):
        if val > 0.5:  # skip zero/near-zero
            ax.text(val + 1.5, i, f'{val:.0f}%', va='center',
                    fontsize=8, fontweight='bold', color=C_TEXT)

    # Section divider text at the spacer row
    spacer_idx = len(emot_items)  # index of the blank spacer row
    ax.text(55, spacer_idx, '─── ▲ VOICE  │  EMOTION ▼ ───', fontsize=7,
            color=C_CYAN, ha='center', va='center', fontweight='bold')

    ax.set_yticks(y_pos)
    ax.set_yticklabels(labels, fontsize=8)
    ax.set_title('Classification Scores', fontsize=9, fontweight='bold')
    ax.set_xlim(0, 115)
    ax.grid(axis='x', alpha=0.2, zorder=0)

    plt.tight_layout(rect=[0, 0, 1, 0.95])
    if SAVE_PLOTS:
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        fn = f'dashboard_{ts}_{r["name"].replace(" ","_").replace(":","")[:20]}.png'
        fig.savefig(fn, dpi=150, bbox_inches='tight', facecolor=fig.get_facecolor())
        print(f"  Saved: {fn}")
    return fig


def plot_comparison(all_r):
    """Create a comparison chart across all analyzed signals."""
    n = len(all_r)
    if n < 2:
        return None
    fig, axes = plt.subplots(2, 3, figsize=(16, 9))
    fig.suptitle('Comparative Analysis Across Signals',
                 fontsize=13, fontweight='bold', y=0.98)
    names = [r['name'][:15] for r in all_r]
    x = np.arange(n); w = 0.5

    # Calmness
    ax = axes[0, 0]
    vals = [r['calmness']['calmness'] for r in all_r]
    ax.bar(x, vals, w, color=C_GREEN, edgecolor=C_EDGE, zorder=3)
    for i, v in enumerate(vals):
        ax.text(i, v+0.2, f'{v:.1f}', ha='center', fontsize=8, color=C_TEXT)
    ax.set_title('Calmness (/10)', fontsize=9)
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=7, rotation=15)
    ax.set_ylim(0, 12); ax.grid(axis='y', alpha=0.3, zorder=0)

    # Harshness
    ax = axes[0, 1]
    vals = [r['calmness']['harshness'] for r in all_r]
    ax.bar(x, vals, w, color=C_RED, edgecolor=C_EDGE, zorder=3)
    for i, v in enumerate(vals):
        ax.text(i, v+0.2, f'{v:.1f}', ha='center', fontsize=8, color=C_TEXT)
    ax.set_title('Harshness (/10)', fontsize=9)
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=7, rotation=15)
    ax.set_ylim(0, 12); ax.grid(axis='y', alpha=0.3, zorder=0)

    # Voice Type
    ax = axes[0, 2]
    vtypes = [r['voice']['voice_type'] for r in all_r]
    confs = [r['voice']['confidence'] for r in all_r]
    cols_v = [C_GREEN if v=='Calm' else C_BLUE if v=='Energetic' else C_RED for v in vtypes]
    ax.bar(x, confs, w, color=cols_v, edgecolor=C_EDGE, zorder=3)
    for i in range(n):
        ax.text(i, confs[i]+1, vtypes[i], ha='center', fontsize=8,
                fontweight='bold', color=cols_v[i])
    ax.set_title('Voice Classification', fontsize=9)
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=7, rotation=15)
    ax.set_ylim(0, 110); ax.grid(axis='y', alpha=0.3, zorder=0)

    # Flatness
    ax = axes[1, 0]
    vals = [r['flatness'] for r in all_r]
    ax.bar(x, vals, w, color=C_CYAN, edgecolor=C_EDGE, zorder=3)
    for i, v in enumerate(vals):
        ax.text(i, v+0.02, f'{v:.3f}', ha='center', fontsize=8, color=C_TEXT)
    ax.set_title('Spectral Flatness (0=tone, 1=noise)', fontsize=9)
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=7, rotation=15)
    ax.grid(axis='y', alpha=0.3, zorder=0)

    # Band Distribution
    ax = axes[1, 1]
    lows = [r['bands']['low_pct'] for r in all_r]
    mids = [r['bands']['mid_pct'] for r in all_r]
    highs = [r['bands']['high_pct'] for r in all_r]
    ax.bar(x, lows, w, color=C_BLUE, label='Low', edgecolor=C_EDGE, zorder=3)
    ax.bar(x, mids, w, bottom=lows, color=C_GREEN, label='Mid', edgecolor=C_EDGE, zorder=3)
    bot2 = [l+m for l,m in zip(lows,mids)]
    ax.bar(x, highs, w, bottom=bot2, color=C_ORANGE, label='High', edgecolor=C_EDGE, zorder=3)
    ax.set_title('Band Energy %', fontsize=9)
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=7, rotation=15)
    ax.legend(fontsize=7, framealpha=0.3); ax.grid(axis='y', alpha=0.3, zorder=0)

    # Emotion
    ax = axes[1, 2]
    emos = [r['emotion']['emotion'] for r in all_r]
    econfs = [r['emotion']['confidence'] for r in all_r]
    ecols = [C_GREEN if e=='Calm' else C_GOLD if e=='Happy' else C_RED if e=='Angry' else C_PURPLE for e in emos]
    ax.bar(x, econfs, w, color=ecols, edgecolor=C_EDGE, zorder=3)
    for i in range(n):
        ax.text(i, econfs[i]+1, emos[i], ha='center', fontsize=8,
                fontweight='bold', color=ecols[i])
    ax.set_title('Emotion Detection', fontsize=9)
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=7, rotation=15)
    ax.set_ylim(0, 110); ax.grid(axis='y', alpha=0.3, zorder=0)

    plt.tight_layout(rect=[0, 0, 1, 0.95])
    if SAVE_PLOTS:
        fig.savefig('comparison_dashboard.png', dpi=150, bbox_inches='tight',
                    facecolor=fig.get_facecolor())
        print("  Saved: comparison_dashboard.png")
    return fig


def plot_similarity_matrix(all_r):
    """Create a heatmap showing pairwise similarity between signals."""
    n = len(all_r)
    if n < 2:
        return None
    mat = np.zeros((n, n))
    for i in range(n):
        for j in range(n):
            if i == j:
                mat[i,j] = 100
            else:
                sim = analyze_similarity(all_r[i], all_r[j])
                mat[i,j] = sim['avg_sim']

    fig, ax = plt.subplots(figsize=(7, 6))
    im = ax.imshow(mat, cmap='RdYlGn', vmin=0, vmax=100)
    names = [r['name'][:12] for r in all_r]
    ax.set_xticks(range(n)); ax.set_xticklabels(names, fontsize=8, rotation=30)
    ax.set_yticks(range(n)); ax.set_yticklabels(names, fontsize=8)
    for i in range(n):
        for j in range(n):
            ax.text(j, i, f'{mat[i,j]:.0f}%', ha='center', va='center',
                    fontsize=9, fontweight='bold',
                    color='black' if mat[i,j] > 50 else 'white')
    fig.colorbar(im, label='Similarity %')
    ax.set_title('5. Signal Similarity Matrix', fontsize=11, fontweight='bold')
    plt.tight_layout()
    if SAVE_PLOTS:
        fig.savefig('similarity_matrix.png', dpi=150, bbox_inches='tight',
                    facecolor=fig.get_facecolor())
        print("  Saved: similarity_matrix.png")
    return fig


# ═══════════════════════════════════════════════════════════════════════
# SECTION 11: POSIT vs NUMPY ACCURACY COMPARISON
# ═══════════════════════════════════════════════════════════════════════

def plot_posit_vs_numpy(results, samples_f64):
    """Compare FPGA posit<32,3> FFT output against NumPy float64 FFT."""
    Xr = results['Xr']; Xi = results['Xi']; mags = results['magnitudes']
    br = results['bin_res_hz']
    freqs = np.arange(N_FFT) * br

    # NumPy reference FFT
    nft = np.fft.fft(samples_f64)
    nmag = np.abs(nft)

    # Error computation
    mae = np.abs(mags - nmag)
    sd = np.where(nmag > 1e-10, nmag, 1.0)
    mre = np.where(nmag > 1e-10, mae/sd*100, np.zeros(N_FFT))

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 7),
                                    gridspec_kw={'height_ratios': [2, 1]})
    xp = np.arange(N_FFT); bw = 0.35; hw = bw/2

    # Magnitude comparison
    ax1.bar(xp-hw, nmag, bw, color=C_ORANGE, alpha=0.85, label='NumPy float64',
            edgecolor=C_EDGE, zorder=3)
    ax1.bar(xp+hw, mags, bw, color=C_BLUE, alpha=0.85, label='Posit FPGA',
            edgecolor=C_EDGE, zorder=3)
    ax1.set_title('Posit<32,3> FPGA vs NumPy float64 FFT', fontsize=11)
    ax1.set_ylabel('Magnitude')
    ax1.set_xticks(xp)
    ax1.set_xticklabels([f'Bin {k}\n{freqs[k]:.0f}Hz' for k in range(N_FFT)], fontsize=8)
    ax1.legend(framealpha=0.2, edgecolor=C_EDGE)
    ax1.grid(axis='y', alpha=0.3, zorder=0)

    # Error bars
    ec = [C_RED if e>5 else C_ORANGE if e>1 else C_GREEN for e in mre]
    ax2.bar(xp, mre, color=ec, edgecolor=C_EDGE, zorder=3)
    for k, e in enumerate(mre):
        if e > 0.01:
            ax2.text(k, e+max(mre)*0.05, f'{e:.3f}%', ha='center', fontsize=8, color=C_TEXT)
    ax2.set_ylabel('Error (%)')
    ax2.set_xlabel('FFT Bin')
    ax2.set_xticks(xp)
    ax2.set_xticklabels([f'Bin {k}' for k in range(N_FFT)], fontsize=8)
    ax2.grid(axis='y', alpha=0.3, zorder=0)

    plt.tight_layout()
    if SAVE_PLOTS:
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        fn = f'posit_vs_numpy_{ts}.png'
        fig.savefig(fn, dpi=150, bbox_inches='tight',
                    facecolor=fig.get_facecolor())
        print(f"  Saved: {fn}")
    return fig


# ═══════════════════════════════════════════════════════════════════════
# SECTION 12: MAIN
# ═══════════════════════════════════════════════════════════════════════
# Reads ONLY from the FPGA outputs produced by step4:
#   - fft_results.npy  -> Xr, Xi, sample_rate, magnitudes, etc.
#   - samples_fp64.npy -> the original 8 time-domain samples from step1
#
# No hardcoded WAV files or synthetic signals.  Every value comes
# from the real FPGA pipeline (step1 -> step2 -> step3 -> step4).

if __name__ == '__main__':

    # ── Verify that the required FPGA output files exist ──────────
    missing = []
    if not os.path.exists(RESULTS_FILE):
        missing.append(RESULTS_FILE)
    if not os.path.exists(SAMPLES_FILE):
        missing.append(SAMPLES_FILE)

    if missing:
        print("ERROR: Missing required FPGA output file(s):")
        for f in missing:
            print(f"  - {f}")
        print("\nMake sure you have run the full pipeline first:")
        print("  1. python step1_audio_extract.py")
        print("  2. python step2_float_to_posit.py")
        print("  3. python step3_uart_tx.py")
        print("  4. python step4_uart_rx.py")
        print("\nThen run this script again.")
        exit(1)

    # ── Load FPGA FFT results and original samples ────────────────
    print("\n" + "="*70)
    print("  LOADING FPGA OUTPUT FILES")
    print("="*70)

    res = np.load(RESULTS_FILE, allow_pickle=True).item()
    samples = np.load(SAMPLES_FILE)

    Xr = res['Xr']
    Xi = res['Xi']
    sr = int(res['sample_rate'])

    print(f"  fft_results.npy  : loaded ({len(Xr)} real + {len(Xi)} imag values)")
    print(f"  samples_fp64.npy : loaded ({len(samples)} samples)")
    print(f"  Sample rate      : {sr} Hz")
    print(f"  Bin resolution   : {sr / N_FFT:.2f} Hz/bin")

    # Show the raw values from the FPGA
    print(f"\n  {'Bin':<5} {'Xr (real)':<20} {'Xi (imag)':<20} {'|Mag|'}")
    print(f"  {'-'*60}")
    for k in range(N_FFT):
        mag = np.sqrt(Xr[k]**2 + Xi[k]**2)
        print(f"  {k:<5} {Xr[k]:<20.8f} {Xi[k]:<20.8f} {mag:.8f}")

    # ── Run full analysis using FPGA Xr/Xi directly ───────────────
    print(f"\n{'='*70}")
    print("  RUNNING ANALYSIS ON FPGA FFT OUTPUT")
    print(f"{'='*70}")

    # Build a minimal signal from the 8 samples (for the frame extraction)
    # Since we already have the exact 8 samples and the FPGA's FFT,
    # we create a wrapper that uses them directly.
    signal_name = "FPGA FFT Output"

    # Run spectrum + band + voice + emotion + calmness analysis
    spec     = analyze_spectrum(Xr, Xi)
    bands    = analyze_bands(spec['magnitudes'])
    flatness = compute_flatness(spec['magnitudes'])
    voice    = classify_voice(bands, flatness)
    emotion  = detect_emotion(bands, flatness)
    calmness = compute_calmness(bands, flatness, spec['magnitudes'])

    # Add frequency info
    bin_res = sr / N_FFT
    spec['bin_res']     = bin_res
    spec['dominant_hz'] = spec['dominant_bin'] * bin_res
    spec['freqs']       = np.arange(N_FFT) * bin_res

    result = dict(
        name=signal_name, sr=sr, frame=samples, spec=spec, bands=bands,
        flatness=flatness, voice=voice, emotion=emotion, calmness=calmness
    )

    # ── Console report ────────────────────────────────────────────
    print_report(result)

    # ── Dashboard plot ────────────────────────────────────────────
    plot_dashboard(result, 0)

    # ── Posit vs NumPy accuracy comparison ────────────────────────
    plot_posit_vs_numpy(res, samples)

    # ── Final summary ─────────────────────────────────────────────
    c = result['calmness']
    print(f"\n{'='*70}")
    print(f"  FINAL RESULT SUMMARY")
    print(f"{'='*70}")
    print(f"  Signal         : {signal_name}")
    print(f"  Sample Rate    : {sr} Hz")
    print(f"  Dominant Freq  : {spec['dominant_hz']:.2f} Hz (bin {spec['dominant_bin']})")
    print(f"  Voice Type     : {voice['voice_type']} ({voice['confidence']:.1f}% conf)")
    print(f"  Emotion        : {emotion['emotion']} ({emotion['confidence']:.1f}% conf)")
    print(f"  Calmness Score : {c['calmness']:.1f} / 10")
    print(f"  Stability      : {c['stability']:.1f} / 10")
    print(f"  Harshness      : {c['harshness']:.1f} / 10")
    print(f"  Spectral Flat. : {flatness:.4f} ({'Tonal' if flatness<0.3 else 'Mixed' if flatness<0.6 else 'Noisy'})")
    print(f"  Dominant Band  : {bands['dominant_band']}")
    print(f"{'='*70}")

    print(f"\nGenerated plot files:")
    for f in sorted([f for f in os.listdir('.') if f.endswith('.png')]):
        print(f"  {f}")