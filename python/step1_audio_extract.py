# step1_audio_extract.py
#
# Reads a WAV file, converts to mono, normalises,
# takes 8 samples aligned to a rising zero-crossing
# so the phase matches the MATLAB reference exactly:
#   sample 1 ≈ -0.707  (one step before the rising zero-crossing)
#
# Saves:
#   samples_fp64.npy  — 8 float64 samples
#   sample_rate.npy   — sample rate in Hz  (used by step4 and step5)

import numpy as np
from scipy.io import wavfile

# ── Configuration ────────────────────────────────────────
WAV_FILE    = 'tone_1000Hz.wav'
N_SAMPLES   = 8
OUTPUT_FILE = 'samples_fp64.npy'
RATE_FILE   = 'sample_rate.npy'
# ─────────────────────────────────────────────────────────


def extract_frame(wav_path, N=8):
    rate, data = wavfile.read(wav_path)
    data = data.astype(np.float64)

    # Convert stereo → mono
    if data.ndim == 2:
        data = np.mean(data, axis=1)

    # Normalise to [-1, 1]
    peak = np.max(np.abs(data))
    if peak > 0:
        data = data / peak

    # ── Find a rising zero-crossing near the centre of the file ──
    # Search within ±1 second of the midpoint
    mid        = len(data) // 2
    search_r   = min(rate, mid - N)          # don't go before start
    search_win = data[mid - search_r : mid + search_r]

    start = None
    for i in range(1, len(search_win) - N):
        if search_win[i - 1] < 0 and search_win[i] >= 0:
            # Rising zero-crossing at index i within search_win.
            # Go one sample earlier so frame starts at ~ -0.707
            # (matches MATLAB: frame = y(mid:mid+N-1) with 1-based indexing)
            abs_start = (mid - search_r) + i - 1
            if abs_start >= 0 and abs_start + N <= len(data):
                start = abs_start
                break

    if start is None:
        # Fallback: original centre-grab (phase may differ from MATLAB)
        print("WARNING: No rising zero-crossing found — using centre window.")
        print("         Phase may not match the MATLAB reference input.")
        start = mid

    frame = data[start : start + N].copy()
    frame = frame - np.mean(frame)           # DC remove
    return frame, rate


def main():
    print(f"Reading: {WAV_FILE}")
    frame, rate = extract_frame(WAV_FILE, N_SAMPLES)

    print(f"Sample rate : {rate} Hz")
    print(f"Samples taken from rising zero-crossing ({len(frame)} samples)\n")

    print(f"{'Sample':<10} {'Float64 Value':<25}")
    print('-' * 38)
    for i, val in enumerate(frame):
        print(f"{i+1:<10} {val:<25.15f}")
    print('-' * 38)

    # Sanity check — sample 1 should be near -0.707 for a 432 Hz sine
    if frame[0] > 0:
        print("\nNOTE: Sample 1 is positive. If it should be ≈ -0.707,")
        print("      the WAV file may start on a different cycle half.")
        print("      Check that tone_432Hz.wav is a pure sine (not cosine).")

    np.save(OUTPUT_FILE, frame)
    np.save(RATE_FILE, np.array([rate]))
    print(f"\nSaved samples → {OUTPUT_FILE}")
    print(f"Saved rate    → {RATE_FILE}  ({rate} Hz)")


if __name__ == '__main__':
    main()