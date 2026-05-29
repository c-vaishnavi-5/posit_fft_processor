# step3_uart_tx.py
#
# Loads samples_uint32.npy written by step2.
# Sends them to the DE10-Standard FPGA over UART via CP2102.
#
# Frame format (matches uart_rx.v exactly):
#   1 byte  : header 0xAA
#   8 x 4 bytes : posit32 samples, MSB first
#   Total   : 33 bytes
#
# Usage:
#   python step3_uart_tx.py              (uses default COM_PORT below)
#   python step3_uart_tx.py COM3         (Windows)
#   python step3_uart_tx.py /dev/ttyUSB0 (Linux)

import sys
import time
import numpy as np
import serial
import serial.tools.list_ports

# ── Configuration ─────────────────────────────────────────
COM_PORT    = 'COM4'          # change to match Device Manager → Ports (COM & LPT)
                               # Look for "Silicon Labs CP210x USB to UART Bridge"
BAUD_RATE   = 115200
INPUT_FILE  = 'samples_uint32.npy'
HEADER      = 0xAA
TIMEOUT_S   = 5
# ──────────────────────────────────────────────────────────


def find_cp2102_port():
    """Auto-detect CP2102 USB-UART adapter port."""
    ports = serial.tools.list_ports.comports()
    for p in ports:
        desc = (p.description or '').upper()
        mfr  = (p.manufacturer or '').upper()
        if 'CP210' in desc or 'CP210' in mfr or 'SILICON' in mfr:
            return p.device
    return None


def build_frame(uint32_array):
    """
    Build the 33-byte UART frame.
    Format: [0xAA] + [8 x posit32 big-endian]
    Matches uart_rx.v header check + word assembly exactly.
    """
    frame = bytearray()
    frame.append(HEADER)
    for val in uint32_array:
        # MSB first — matches uart_rx.v build[31:24]..build[7:0]
        # Cast to Python int first — numpy.uint32 has no .to_bytes()
        frame += int(val).to_bytes(4, byteorder='big')
    return bytes(frame)


def main():
    # ── Resolve COM port ──────────────────────────────────
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
            print("If this is wrong, run:  python step3_uart_tx.py COMx")

    # ── Load posit samples from step2 ────────────────────
    print(f"\nLoading: {INPUT_FILE}")
    samples = np.load(INPUT_FILE)
    print(f"Loaded {len(samples)} posit32 samples")

    if len(samples) != 8:
        print(f"ERROR: expected 8 samples, got {len(samples)}")
        sys.exit(1)

    # Print what we're sending
    print(f"\n{'Sample':<10} {'uint32 (hex)':<14} {'uint32 (dec)'}")
    print('-' * 40)
    for i, val in enumerate(samples):
        print(f"{i:<10} 0x{val:08X}     {val}")
    print('-' * 40)

    # ── Build frame ───────────────────────────────────────
    frame = build_frame(samples)
    print(f"\nFrame ({len(frame)} bytes):")
    print(' '.join(f'{b:02X}' for b in frame))

    # ── Open serial port and send ─────────────────────────
    print(f"\nOpening {port} at {BAUD_RATE} baud...")
    try:
        ser = serial.Serial(
            port     = port,
            baudrate = BAUD_RATE,
            bytesize = serial.EIGHTBITS,
            parity   = serial.PARITY_NONE,
            stopbits = serial.STOPBITS_ONE,
            timeout  = TIMEOUT_S
        )
    except serial.SerialException as e:
        print(f"ERROR opening port: {e}")
        print("\nAvailable ports:")
        for p in serial.tools.list_ports.comports():
            print(f"  {p.device}  —  {p.description}")
        sys.exit(1)

    time.sleep(0.1)   # let port settle
    ser.reset_input_buffer()
    ser.reset_output_buffer()

    print("Sending frame to FPGA...")
    ser.write(frame)
    ser.flush()

    print(f"\nDone. {len(frame)} bytes sent.")
    print("Check FPGA: LEDR[0] should now be ON (frame received).")
    print("Press KEY[1] on the DE10 to start FFT.")

    ser.close()


if __name__ == '__main__':
    main()