#!/bin/bash
# Is the LimeSDR actually receiving anything?
#
# Written for the moment an antenna is attached: run this and it says, within a minute, whether
# the RF input is delivering signal or whether you are still looking at the receiver's own noise
# floor. It is also the check that proves the "no antenna" conclusion in docs/hardware.md.
#
# What it does:
#   1. captures a couple of seconds straight from SoapySDR and reports the sample spread;
#   2. starts ogn-rf, drains its output FIFO so the pipeline is not the bottleneck, and reports
#      the live-time figure ogn-rf computes for itself.
#
# Interpreting the spread (sd of the 8-bit samples, with 128 as zero):
#   < 1.5   nothing on the input - receiver noise floor / no RF connected
#   1.5-5   something is attached; a quiet band
#   > 5     real signal present (an OGN receiver with an antenna typically sits here)
#
# Usage: ./verify-reception.sh [seconds]      default 30
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SECS=${1:-30}
CONF=$HERE/../config/ogn-rf-limesdr.conf
BIN=$HERE/../limesdr_probe
OGN=${OGN:-$HERE/../ogn-rf/ogn-rf}

echo "==================== 1. raw sample spread ===================="
if [ ! -x "$BIN" ]; then
  g++ -O2 -o "$BIN" "$HERE/../src/limesdr_probe.cc" -lSoapySDR || { echo "build failed" >&2; exit 1; }
fi

CAP=$("$BIN" -n 2000000 -g 50 2>&1 | grep -vE "^\[INFO\]")
echo "$CAP" | grep -E "^(device|serial|8-bit|clipping|throughput)"

SD=$(echo "$CAP" | sed -n 's/.*8-bit (>>[0-9]*) *: mean *[0-9.]* *sd *\([0-9.]*\).*/\1/p')
if [ -z "$SD" ]; then
  echo "could not read the sample spread - capture failed" >&2
  exit 1
fi

echo
if awk "BEGIN{exit !($SD < 1.5)}"; then
  echo "VERDICT: no RF input. Sample spread ${SD} is the receiver's own noise floor."
  echo "         Attach an antenna to RX1_L (the LNAL path is selected for 868 MHz) and re-run."
  WEAK=1
elif awk "BEGIN{exit !($SD < 5)}"; then
  echo "VERDICT: something is connected but the band looks quiet (spread ${SD})."
  WEAK=0
else
  echo "VERDICT: real signal present (spread ${SD})."
  WEAK=0
fi

echo
echo "==================== 2. ogn-rf live time ===================="
if [ ! -x "$OGN" ]; then
  echo "no ogn-rf at $OGN - skipping (build it with ../scripts/build-ogn-rf.sh)" >&2
  exit 0
fi
if ! command -v curl >/dev/null; then
  echo "curl not available - skipping" >&2
  exit 0
fi

PORT=$(sed -n 's/.*Port *= *\([0-9]*\).*/\1/p' "$CONF" | head -1)
PORT=${PORT:-8095}
DIR=$(dirname "$OGN")

cd "$DIR" || exit 1
[ -r "$CONF" ] || { echo "cannot read $CONF" >&2; exit 1; }

# ogn-rf needs stdin open, and line buffering to log anything at all
setsid bash -c "sleep infinity | stdbuf -oL -eL '$OGN' '$CONF' > /tmp/ogn-rf-verify.log 2>&1" \
  < /dev/null > /dev/null 2>&1 &
sleep 6

# Drain the FIFO, otherwise nothing consumes OutQueue and the live time stays near zero
( timeout "$SECS" cat "$DIR/ogn-rf.fifo" > /dev/null & ) 2>/dev/null

sleep "$SECS"
LIVE=$(curl -s --max-time 10 "http://127.0.0.1:$PORT/" 2>/dev/null |
       sed -e 's/<[^>]*>/|/g' | tr -s '|' '|' | sed -n 's/.*|Live Time| *\([0-9.]*\)%.*/\1/p' | head -1)

pkill -x ogn-rf 2>/dev/null || true

echo "ogn-rf live time: ${LIVE:-unknown} %   (100 % = every time slot read and handed on)"
if [ -n "${LIVE:-}" ]; then
  if awk "BEGIN{exit !($LIVE > 80)}"; then
    echo "VERDICT: the receiver is keeping up with real time."
  else
    echo "VERDICT: live time is low - the DSP chain is not keeping up, not the radio."
    echo "         Check the log: /tmp/ogn-rf-verify.log"
  fi
fi

if [ "${WEAK:-0}" = 1 ]; then
  echo
  echo "Remember: with no RF input, nothing can decode. The plumbing is verified; the antenna is not."
fi
