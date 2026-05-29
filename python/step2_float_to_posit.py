# step2_float_to_posit.py
#
# Loads samples_fp64.npy written by step1.
# Converts each float64 sample to posit<32, es=3>
# with maximum 5 regime bits — matching your Verilog
# data_extract_5bit_regime module exactly.
#
# Prints the same table as your MATLAB script.
# Saves posit bit strings to  samples_posit32.npy
# and uint32 values to        samples_uint32.npy  (ready for UART TX)

import math
import numpy as np

# ── Configuration ────────────────────────────────────────
INPUT_FILE       = 'samples_fp64.npy'
OUTPUT_BITS_FILE = 'samples_posit32.npy'   # array of bit strings
OUTPUT_U32_FILE  = 'samples_uint32.npy'    # array of uint32 integers
N  = 32   # posit word width
ES = 3    # exponent bits
MAX_REGIME_BITS = 5   # from your Verilog: 5-bit regime max
# ─────────────────────────────────────────────────────────


# ── Helper: binary addition ───────────────────────────────
def bin_add_one(b: str) -> str:
    """Add 1 to a binary string. Matches MATLAB bin_add_one."""
    bits  = [int(c) for c in b]
    carry = 1
    for i in range(len(bits) - 1, -1, -1):
        s       = bits[i] + carry
        bits[i] = s % 2
        carry   = s // 2
        if carry == 0:
            break
    return ''.join(str(c) for c in bits)


def twos_complement(b: str) -> str:
    """Two's complement of a binary string. Matches MATLAB twos_complement."""
    inv = ''.join('1' if c == '0' else '0' for c in b)
    return bin_add_one(inv)


# ── Main encoder ─────────────────────────────────────────
def dec2pos_correct(x: float, n: int = 32, es: int = 3,
                    max_regime_bits: int = 5) -> str:
    """
    Convert float64 → posit<n, es> bit string.

    Exact translation of your MATLAB dec2pos_correct,
    with the additional max_regime_bits=5 constraint
    that matches your data_extract_5bit_regime Verilog.

    Parameters
    ----------
    x               : value to encode
    n               : posit word width (32)
    es              : exponent bits (3)
    max_regime_bits : maximum regime field width (5)
    """
    useed = 2 ** (2 ** es)    # 2^8 = 256

    # ── Special cases ─────────────────────────────────────
    if x == 0.0:
        return '0' * n
    if math.isinf(x):
        return '1' + '0' * (n - 1)   # NaR

    sign = x < 0
    x    = abs(x)

    # ── Regime: find k ────────────────────────────────────
    # Reduce x into [1, useed) by multiplying/dividing by useed.
    # Matches MATLAB while-loop regime finder exactly.
    k  = 0
    xw = x
    if xw >= 1:
        while xw >= useed:
            xw /= useed
            k  += 1
    else:
        while xw < 1:
            xw *= useed
            k  -= 1

    # Clamp k to the 5-bit regime limit from your Verilog.
    # Verilog handles k = -5 .. +4  (regime lengths 1..6 but capped at 5 bits)
    # k >= 0: regime = (k+1) ones + zero  → length k+2
    # k <  0: regime = (-k) zeros + one   → length -k+1
    # Maximum regime field = 5 bits → k_max = +4, k_min = -5
    k = max(-5, min(k, 4))

    if k >= 0:
        reg = '1' * (k + 1) + '0'   # e.g. k=2  → '1110'
    else:
        reg = '0' * (-k) + '1'      # e.g. k=-2 → '001'

    # Enforce the 5-bit cap on regime bits in the output
    reg = reg[:max_regime_bits + 1]  # allow one extra for the terminator

    # ── Exponent ──────────────────────────────────────────
    # xw is now in [1, useed). Extract es-bit binary exponent.
    exp_val  = int(math.floor(math.log2(xw)))
    exp_val  = max(0, min(exp_val, (2 ** es) - 1))   # clamp to [0, 7]
    xw       = xw / (2 ** exp_val)                   # normalise to [1, 2)
    exp_bits = bin(exp_val)[2:].zfill(es)             # always 3 bits

    # ── Fraction ──────────────────────────────────────────
    frac_len   = n - 1 - len(reg) - es   # bits available in word
    extra      = 3                        # guard + round + sticky
    total_frac = frac_len + extra

    frac      = xw - 1.0    # fractional part of normalised significand
    frac_bits = ''
    for _ in range(max(total_frac, 0)):
        frac *= 2
        if frac >= 1.0:
            frac_bits += '1'
            frac      -= 1.0
        else:
            frac_bits += '0'

    # ── Assemble magnitude field (no sign bit yet) ────────
    posit_wo_sign = reg + exp_bits + frac_bits
    posit_wo_sign = posit_wo_sign[:n - 1 + extra]

    # ── Round to nearest, ties to even ───────────────────
    # Matches MATLAB rounding logic exactly
    main   = list(posit_wo_sign[:n - 1])
    guard  = posit_wo_sign[n - 1] if len(posit_wo_sign) > n - 1 else '0'
    roundb = posit_wo_sign[n]     if len(posit_wo_sign) > n     else '0'
    sticky = ('1' in posit_wo_sign[n + 1:]) if len(posit_wo_sign) > n + 1 else False

    if guard == '1' and (roundb == '1' or sticky or main[-1] == '1'):
        main = list(bin_add_one(''.join(main)))

    bits = '0' + ''.join(main)   # sign bit = 0 for positive

    # ── Apply sign ────────────────────────────────────────
    if sign:
        bits = twos_complement(bits)

    return bits


# ── Main ─────────────────────────────────────────────────
def main():
    # Load float64 samples from step1
    frame = np.load(INPUT_FILE)
    n_samples = len(frame)

    print(f"\n===== POSIT REPRESENTATION OF {n_samples} SAMPLES =====")
    print(f"posit<{N}, es={ES}>   max regime bits = {MAX_REGIME_BITS}")
    print(f"useed = {2**(2**ES)}\n")

    # Header — matches your MATLAB fprintf layout
    print(f"{'Sample':<10} {'Frame Value':<22} {'Posit Bits (32-bit)':<34} {'Hex'}")
    print('-' * 78)

    posit_bits_list = []
    uint32_list     = []

    for i, val in enumerate(frame):
        bits    = dec2pos_correct(val, N, ES, MAX_REGIME_BITS)
        hx      = hex(int(bits, 2))[2:].upper().zfill(8)
        posit_bits_list.append(bits)
        uint32_list.append(int(bits, 2))
        print(f"{i+1:<10} {val:<22.10f} {bits}  0x{hx}")

    print('-' * 78)

    # Save outputs
    np.save(OUTPUT_BITS_FILE, np.array(posit_bits_list))
    np.save(OUTPUT_U32_FILE,  np.array(uint32_list, dtype=np.uint32))

    print(f"\nSaved bit strings → {OUTPUT_BITS_FILE}")
    print(f"Saved uint32 values → {OUTPUT_U32_FILE}")
    print(f"\nThese uint32 values are what step3_uart_tx.py will send to the FPGA.")


if __name__ == '__main__':
    main()

