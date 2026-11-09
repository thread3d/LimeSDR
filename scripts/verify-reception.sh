#!/bin/bash
# Is the LimeSDR actually receiving anything?
#
# The trap this script exists to avoid: judging the receiver by the sample spread at 868 MHz.
# That band is genuinely quiet most of the time, so a perfectly healthy antenna there looks
# exactly like no antenna at all. The test that actually separates the two cases is a comparison -
# measure a band that is certainly busy (LTE800 downlink, 791-821 MHz) and compare it with the
# target band. A connected antenna makes the busy band louder by 15-20 dB; an unconnected port
# makes both equally dead.
#
# What it does:
#   1. captures the OGN band and the busy reference band at identical settings and compares them;
#   2. starts ogn-rf, drains its output FIFO so the DSP pipeline is not the bottleneck, and
#      reports the live-time figure ogn-rf computes for itself.
#
# Usage: ./verify-reception.sh [seconds]      default 20
#        GAIN=40 ./verify-reception.sh        probe at a different gain
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SECS=${1:-20}
CONF=$HERE/../config/ogn-rf-limesdr.conf
BIN=$HERE/../limesdr_probe
OGN=${OGN:-$HERE/../../ogn-rf/ogn-rf}
RATE=1000000
GAIN=${GAIN:-61}

echo "==================== 1. is the front end alive? ===================="
if [ ! -x "$BIN" ]; then
  g++ -O2 -o "$BIN" "$HERE/../src/limesdr_probe.cc" -lSoapySDR || { echo "build failed" >&2; exit 1; }
fi

# Standard deviation of the 8-bit samples at a given frequency, identical settings both times
spread() { "$BIN" -f "$1" -r "$RATE" -g "$GAIN" -n 2000000 -q 2>/dev/null |
           sed -n 's/.*8-bit (>>[0-9]*) *: mean *[0-9.]* *sd *\([0-9.]*\).*/\1/p' | head -1; }

SD_OGN=$(spread 868300000)
SD_REF=$(spread 800000000)

if [ -z "$SD_OGN" ] || [ -z "$SD_REF" ]; then
  echo "capture failed - is the device present?" >&2
  exit 1
fi

echo "OGN band   868.3 MHz : sample spread ${SD_OGN}"
echo "reference  800.0 MHz : sample spread ${SD_REF}   (LTE800 downlink, always busy)"
RATIO=$(awk "BEGIN{ if ($SD_OGN>0) printf \"%.1f\", 20*log($SD_REF/$SD_OGN)/log(10); else print 99 }")
echo "difference           : ${RATIO} dB"

echo
ALIVE=0
if awk "BEGIN{exit !($RATIO > 8)}"; then
  ALIVE=1
  echo "VERDICT: the front end is live - the busy band is ${RATIO} dB louder than 868.3 MHz,"
  echo "         which only a connected antenna produces."
  if awk "BEGIN{exit !($SD_OGN < 2)}"; then
    echo "         The 868 MHz band itself is quiet (spread ${SD_OGN}): no OGN transmitter is"
    echo "         audible right now. That is ordinary for OGN - re-run later or wait for traffic."
  else
    echo "         There is activity in the OGN band (spread ${SD_OGN})."
  fi
elif awk "BEGIN{exit !($SD_REF < 1.5)}"; then
  echo "VERDICT: no RF input. Both bands sit on the receiver's own floor, so nothing is"
  echo "         connected, or the cable/connector has failed. Check RX1_L."
else
  echo "VERDICT: ambiguous - the reference band is only ${RATIO} dB above the OGN band."
  echo "         Check the antenna and its connector."
fi

echo
echo "==================== 2. ogn-rf live time ===================="
if [ ! -x "$OGN" ]; then
  echo "no ogn-rf at $OGN - skipping (build it with ../scripts/build-ogn-rf.sh)" >&2
  exit 0
fi
command -v curl >/dev/null || { echo "curl not available - skipping" >&2; exit 0; }

PORT=$(sed -n 's/.*Port *= *\([0-9]*\).*/\1/p' "$CONF" | head -1)
PORT=${PORT:-8095}
DIR=$(dirname "$OGN")

cd "$DIR" || exit 1
[ -r "$CONF" ] || { echo "cannot read $CONF" >&2; exit 1; }

pkill -x ogn-rf 2>/dev/null
sleep 1
# ogn-rf needs stdin open, and line buffering to log anything at all. The producer is a BOUNDED
# sleep, not "sleep infinity": when this script kills ogn-rf afterwards, an endless producer would
# outlive it and leave a stray pipeline behind on every run (which is exactly what happened).
setsid bash -c "sleep $((SECS+15)) | stdbuf -oL -eL '$OGN' '$CONF' > /tmp/ogn-rf-verify.log 2>&1" \
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
  if awk "BEGIN{exit !($LIVE > 60)}"; then
    echo "VERDICT: the receiver is reading and passing on most time slots."
  else
    echo "VERDICT: live time is low. Either the DSP chain cannot keep up, or nothing drained"
    echo "         the output FIFO (ogn-rf halves then drops slots when its OutQueue fills)."
    echo "         It is not in itself evidence about the radio. Log: /tmp/ogn-rf-verify.log"
  fi
fi

if [ "$ALIVE" = 1 ] && awk "BEGIN{exit !($SD_OGN < 2)}"; then
  echo
  echo "Summary: hardware and software chain verified; nothing to decode until an OGN"
  echo "         transmitter is in range. ./spectrum-limesdr.sh 868.3 shows the band."
fi
