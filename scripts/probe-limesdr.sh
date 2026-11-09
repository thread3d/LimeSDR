#!/bin/bash
# Look at the LimeSDR directly, with no involvement from ogn-rf.
#
# This is the first thing to run when something is wrong: it separates "the radio is not
# delivering sensible samples" from "ogn-rf's DSP is unhappy about sensible samples".
#
# Usage:
#   ./probe-limesdr.sh                 device summary + one capture at the default gain
#   ./probe-limesdr.sh --sweep         gain sweep (find a gain that fills the 8-bit range)
#   ./probe-limesdr.sh --antennas      same capture on every LNA path (is anything connected?)
#   ./probe-limesdr.sh --test-tone     enable the LMS7002M digital test tone (check the scale)
#   ./probe-limesdr.sh --rate 2000000  sample rate in Hz
#   ./probe-limesdr.sh --gain 40       gain in dB
#   ./probe-limesdr.sh --freq 868300000
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$HERE/../limesdr_probe
SRC=$HERE/../src/limesdr_probe.cc
FREQ=868300000
RATE=1000000
GAIN=50
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --sweep)     ARGS+=(-s 0,10,20,30,40,50,61); shift ;;
    --antennas)  ARGS+=(-A); shift ;;
    --test-tone) ARGS+=(-t); shift ;;
    --rate)      RATE=$2; shift 2 ;;
    --gain)      GAIN=$2; shift 2 ;;
    --freq)      FREQ=$2; shift 2 ;;
    -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "unknown option $1 (try --help)" >&2; exit 1 ;;
  esac
done

# Build on demand
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  echo "building limesdr_probe ..."
  g++ -O2 -o "$BIN" "$SRC" -lSoapySDR || { echo "build failed" >&2; exit 1; }
fi

echo "==================== what SoapySDR says ===================="
SoapySDRUtil --probe="driver=lime" 2>&1 | grep -vE "^\[INFO\]" | \
  grep -E "^(Probe|  *(driver|hardware|boardSerialNumber|firmwareVersion|gatewareVersion|hardwareVersion|protocolVersion|Antennas|Full gain range|Sample rates|Stream formats|Native format))|WARNING|Expected gateware|But found" | head -40

echo
echo "==================== sample capture ===================="
exec "$BIN" -f "$FREQ" -r "$RATE" -g "$GAIN" "${ARGS[@]}"
