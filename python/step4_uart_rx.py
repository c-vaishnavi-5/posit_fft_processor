# step4_uart_rx.py
#
# Receives FFT results from the DE10-Standard FPGA over UART via CP2102.
# Converts posit32 outputs back to float64 for analysis.
#
# Frame format (matches uart_tx.v exactly):
#   1 byte   : header 0xBB
#   16 x 4 bytes : posit32 values MSB first
#                  order: X0r, X0i, X1r, X1i, ... X7r, X7i
#   Total    : 65 bytes
#
# Reads sample rate from sample_rate.npy (written by step1).
# Saves results to fft_results.npy for step5.
#
# Usage:
#   python step4_uart_rx.py              (uses default COM_PORT)
#   python step4_uart_rx.py COM5         (Windows)
#   python step4_uart_rx.py /dev/ttyUSB0 (Linux)

import sys
import time
import math
import os
import numpy as np
import serial
import serial.tools.list_ports

# ── Configuration ─────────────────────────────────────────
COM_PORT     = 'COM3'          # change to your port from Device Manager
BAUD_RATE    = 115200
HEADER       = 0xBB
N_WORDS      = 16              # 8 complex outputs = 16 x posit32
FRAME_BYTES  = 1 + N_WORDS * 4  # 65 bytes total
TIMEOUT_S    = 30              # wait up to 30s for KEY[2] press
RATE_FILE    = 'sample_rate.npy'
OUTPUT_FILE  = 'fft_results.npy'
ES           = 3
# ──────────────────────────────────────────────────────────


def find_cp2102_port():
    ports = serial.tools.list_ports.comports()
    for p in ports:
        desc = (p.description or '').upper()
        mfr  = (p.manufacturer or '').upper()
        if 'CP210' in desc or 'CP210' in mfr or 'SILICON' in mfr:
            return p.device
    return None


def posit32_to_float(bits: int) -> float:
    N     = 32
    useed = 2 ** (2 ** ES)

    if bits == 0x00000000:
        return 0.0
    if bits == 0x80000000:
        return float('inf')

    sign = (bits >> (N - 1)) & 1
    if sign:
        mag = ((~bits) + 1) & 0xFFFFFFFF
    else:
        mag = bits

    if mag == 0:
        return 0.0

    pos     = N - 2
    run_bit = (mag >> pos) & 1
    k       = 0

    if run_bit == 1:
        while pos >= 0 and ((mag >> pos) & 1) == 1:
            k  += 1
            pos -= 1
        k   -= 1
        pos -= 1
    else:
        while pos >= 0 and ((mag >> pos) & 1) == 0:
            k  -= 1
            pos -= 1
        pos -= 1

    exp_val = 0
    for e in range(ES - 1, -1, -1):
        if pos >= 0:
            exp_val |= ((mag >> pos) & 1) << e
            pos -= 1

    frac = 1.0
    fw   = 0.5
    while pos >= 0:
        if (mag >> pos) & 1:
            frac += fw
        fw  *= 0.5
        pos -= 1

    value = (useed ** k) * (2 ** exp_val) * frac
    return -value if sign else value


def receive_frame(ser):
    print("Waiting for FPGA transmission...")
    print("(Press KEY[2] on the DE10 to send results)\n")

    # Scan for header byte
    while True:
        byte = ser.read(1)
        if len(byte) == 0:
            print("ERROR: Timeout — no data received from FPGA.")
            print("Make sure:")
            print("  1. LEDR[2] is ON (results ready)")
            print("  2. You pressed KEY[2] on the DE10")
            print("  3. CP2102 RX is connected to GPIO[1] (PIN_AK2)")
            return None

        if byte[0] == HEADER:
            print(f"Header 0x{HEADER:02X} received — reading {N_WORDS * 4} data bytes...")
            break
        else:
            print(f"  Skipping byte: 0x{byte[0]:02X}")

    # Read remaining 64 bytes
    data = ser.read(N_WORDS * 4)
    if len(data) != N_WORDS * 4:
        print(f"ERROR: Expected {N_WORDS * 4} bytes, got {len(data)}")
        return None

    words = []
    for i in range(N_WORDS):
        w = (data[i*4]     << 24) | (data[i*4+1] << 16) | \
            (data[i*4+2]   <<  8) |  data[i*4+3]
        words.append(w)
    return words


def main():
    # ── Port ─────────────────────────────────────────────
    port = sys.argv[1] if len(sys.argv) > 1 else None
    if port is None:
        port = find_cp2102_port()
        if port:
            print(f"Auto-detected CP2102 on: {port}")
        else:
            print("CP2102 not auto-detected. Available ports:")
            for p in serial.tools.list_ports.comports():
                print(f"  {p.device}  —  {p.description}")
            port = COM_PORT
            print(f"Using default: {port}")
            print("If wrong, run:  python step4_uart_rx.py COMx")

    # ── Sample rate ───────────────────────────────────────
    if os.path.exists(RATE_FILE):
        sample_rate = int(np.load(RATE_FILE)[0])
        print(f"Sample rate from {RATE_FILE}: {sample_rate} Hz")
    else:
        try:
            sample_rate = int(input("Enter sample rate (Hz) from step1 output: "))
        except (ValueError, EOFError):
            sample_rate = 3456
            print(f"Using default: {sample_rate} Hz")

    N_FFT      = 8
    bin_res_hz = sample_rate / N_FFT

    # ── Open port ─────────────────────────────────────────
    print(f"\nOpening {port} at {BAUD_RATE} baud...")
    try:
        ser = serial.Serial(
            port=port, baudrate=BAUD_RATE,
            bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE, timeout=TIMEOUT_S
        )
    except serial.SerialException as e:
        print(f"ERROR opening port: {e}")
        for p in serial.tools.list_ports.comports():
            print(f"  {p.device}  —  {p.description}")
        sys.exit(1)

    time.sleep(0.1)
    ser.reset_input_buffer()

    # ── Receive ───────────────────────────────────────────
    words = receive_frame(ser)
    ser.close()
    if words is None:
        sys.exit(1)

    # ── Decode posit32 → float64 ──────────────────────────
    Xr = []
    Xi = []
    for k in range(8):
        Xr.append(posit32_to_float(words[k * 2]))
        Xi.append(posit32_to_float(words[k * 2 + 1]))

    # ── Print results ─────────────────────────────────────
    print(f"\n{'='*65}")
    print(f"  FFT OUTPUT  (posit32 decoded to float64)")
    print(f"{'='*65}")
    print(f"{'Bin':<6} {'Real':<22} {'Imag':<22} {'|Magnitude|'}")
    print(f"{'-'*65}")

    magnitudes = []
    for k in range(8):
        mag = math.sqrt(Xr[k]**2 + Xi[k]**2)
        magnitudes.append(mag)
        print(f"  {k:<4} {Xr[k]:<22.8f} {Xi[k]:<22.8f} {mag:.8f}")
    print(f"{'-'*65}")

    # ── Frequency analysis ────────────────────────────────
    search_bins = [1, 2, 3, 4]
    dom_bin     = max(search_bins, key=lambda k: magnitudes[k])
    dom_freq_hz = dom_bin * bin_res_hz

    print(f"\n{'='*65}")
    print(f"  FREQUENCY ANALYSIS")
    print(f"  Sample rate    : {sample_rate} Hz")
    print(f"  Bin resolution : {bin_res_hz:.2f} Hz/bin")
    print(f"{'='*65}")
    for k in search_bins:
        marker = " \u2190 DOMINANT" if k == dom_bin else ""
        print(f"  Bin {k}: {k * bin_res_hz:8.2f} Hz   magnitude = {magnitudes[k]:.6f}{marker}")
    print(f"\n  Dominant frequency : {dom_freq_hz:.2f} Hz  (bin {dom_bin})")
    print(f"{'='*65}\n")

    # ── Save ──────────────────────────────────────────────
    results = {
        'Xr'          : np.array(Xr),
        'Xi'          : np.array(Xi),
        'magnitudes'  : np.array(magnitudes),
        'dominant_bin': dom_bin,
        'dominant_hz' : dom_freq_hz,
        'sample_rate' : sample_rate,
        'bin_res_hz'  : bin_res_hz,
        'raw_uint32'  : np.array(words, dtype=np.uint32)
    }
    np.save(OUTPUT_FILE, results)
    print(f"Results saved to: {OUTPUT_FILE}")
    print(f"Now run:  python step5_fft_analysis.py")

if __name__ == '__main__':
    main()