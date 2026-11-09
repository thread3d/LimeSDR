#!/bin/bash
# Capture the spectrum around one frequency and describe it.
#
# This is the tool to reach for when the question is "what is actually on the air here?" rather
# than "is the receiver working?". It captures one wide chunk in a single tuning, so there is no
# retune-per-step behaviour to confuse the reading - retuning re-runs the LMS7002M calibration on
# every step, which makes step-by-step power scans noisy and hard to reproduce.
#
# Usage:
#   ./spectrum-limesdr.sh 868.3            capture 4 MSps around 868.3 MHz and describe it
#   ./spectrum-limesdr.sh 800 2 40         ... at 2 MSps and 40 dB gain
#   ./spectrum-limesdr.sh 868.3 4 61 1.0   ... and profile only +-0.5 MHz around the centre
#
# Arguments:  <centre MHz> [rate MSps] [gain dB] [profile span MHz] [fft size]
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PROBE=$HERE/../limesdr_probe
SRC=$HERE/../src/limesdr_probe.cc
TOOL=$HERE/../tools/spectrum.py

CENTRE=${1:-868.3}
RATE=${2:-4}
GAIN=${3:-61}
SPAN=${4:-0}
FFT=${5:-4096}

# Build the pieces on demand
if [ ! -x "$PROBE" ] || [ "$SRC" -nt "$PROBE" ]; then
  echo "building limesdr_probe ..." >&2
  g++ -O2 -o "$PROBE" "$SRC" -lSoapySDR || { echo "probe build failed" >&2; exit 1; }
fi
command -v python3 >/dev/null || { echo "python3 is required for the analysis" >&2; exit 1; }
python3 -c "import numpy" 2>/dev/null || { echo "numpy is required: sudo apt install python3-numpy" >&2; exit 1; }

TMP=$(mktemp /tmp/limesdr-spectrum-XXXXXX.u8) || exit 1
trap 'rm -f "$TMP"' EXIT

SAMPLES=$(python3 -c "print(int($RATE*1e6))")

echo "capturing ${RATE} MSps at ${CENTRE} MHz, ${GAIN} dB gain ..."
if ! "$PROBE" -f "$(python3 -c "print(int($CENTRE*1e6))")" -r "$SAMPLES" \
              -g "$GAIN" -n "$SAMPLES" -o "$TMP" -q 2>/dev/null; then
  echo "capture failed" >&2
  exit 1
fi

echo
python3 "$TOOL" "$TMP" "$SAMPLES" "$(python3 -c "print(int($CENTRE*1e6))")" \
        --fft "$FFT" --span "$SPAN" --bins "${BINS:-28}"
