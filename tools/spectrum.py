#!/usr/bin/env python3
"""Spectrum / power analysis of an interleaved 8-bit I/Q capture.

Reads the .u8 files that limesdr_probe -o writes and reports an averaged power spectral
density, so the OGN channels can be judged on the spectrum itself instead of on a
retune-and-measure scan (retuning re-runs the LMS7002M calibration, which makes per-step
power estimates noisy and hard to reproduce).

Usage: spectrum.py file.u8 rate_hz centre_hz [--fft N] [--bins N] [--span MHz]
"""
import sys, argparse
import numpy as np


def load(path):
    raw = np.fromfile(path, dtype=np.uint8)
    if raw.size % 2:
        raw = raw[:-1]
    iq = (raw.astype(np.float32) - 128.0) / 128.0
    return iq[0::2] + 1j * iq[1::2]


def welch(x, nfft):
    """Averaged periodogram, Hann window, 50% overlap."""
    w = np.hanning(nfft).astype(np.float32)
    step = nfft // 2
    acc = np.zeros(nfft, dtype=np.float64)
    frames = 0
    for start in range(0, len(x) - nfft, step):
        seg = x[start:start + nfft] * w
        acc += np.abs(np.fft.fftshift(np.fft.fft(seg))) ** 2
        frames += 1
    if frames == 0:
        raise SystemExit("capture too short for the requested FFT size")
    # normalise so the result is power per bin in dBFS (full-scale sine -> 0 dB)
    acc /= frames
    acc /= (np.sum(w) ** 2) / 4.0
    return np.fft.fftshift(np.fft.fftfreq(nfft)), acc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("rate", type=float, help="sample rate, Hz")
    ap.add_argument("centre", type=float, help="centre frequency, Hz")
    ap.add_argument("--fft", type=int, default=4096)
    ap.add_argument("--bins", type=int, default=40, help="how many rows to print")
    ap.add_argument("--span", type=float, default=0.0, help="zoom width in MHz around centre")
    a = ap.parse_args()

    x = load(a.path)
    print(f"capture   : {len(x)} complex samples, {len(x)/a.rate:.3f} s at {a.rate/1e6:.3f} MSps")
    print(f"centre    : {a.centre/1e6:.6f} MHz")

    freq, psd = welch(x, a.fft)          # freq is cycles/sample, -0.5 .. +0.5
    absf = a.centre + freq * a.rate     # -> absolute Hz
    db = 10 * np.log10(psd + 1e-30)

    floor = np.median(db)
    print(f"noise floor (median bin) : {floor:7.2f} dBFS")
    print(f"peak                     : {db.max():7.2f} dBFS at {absf[db.argmax()]/1e6:.4f} MHz")
    print(f"peak over floor          : {db.max()-floor:7.2f} dB")

    # Where are the OGN channels?
    for ch, mhz in (("868.200", 868.2e6), ("868.400", 868.4e6)):
        idx = int(np.argmin(np.abs(absf - mhz)))
        band = db[max(0, idx-3):idx+4]
        print(f"OGN {ch} MHz            : {band.max():7.2f} dBFS (max within +-3 bins) "
              f"-> {band.max()-floor:+.2f} dB re floor")

    # Coarse profile
    lo = a.centre - (a.span/2 * 1e6 if a.span else a.rate / 2)
    hi = a.centre + (a.span/2 * 1e6 if a.span else a.rate / 2)
    edges = np.linspace(lo, hi, a.bins + 1)
    print("\n  from [MHz]    to [MHz]   dBFS   profile")
    top = db.max()
    for k in range(a.bins):
        sel = (absf >= edges[k]) & (absf < edges[k + 1])
        if not sel.any():
            continue
        val = 10 * np.log10(np.mean(psd[sel]) + 1e-30)
        bar = int(max(0, (val - floor) / max(top - floor, 1e-9) * 50))
        print(f"  {edges[k]/1e6:10.4f}  {edges[k+1]/1e6:10.4f}  {val:7.2f}  " + "#" * bar)


if __name__ == "__main__":
    main()
