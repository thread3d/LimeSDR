#!/bin/bash
# Run ogn-rf against a LimeSDR.
#
# Two traps make a perfectly healthy ogn-rf look completely dead, so this script handles both:
#
#   1. stdin.  main() runs "while(!RF.StopReq) { if(fgets(Cmd,128,stdin)==0) break; ... }".
#      If stdin is at EOF - a script, nohup, /dev/null, most service managers - it breaks out at
#      once, stops the acquisition thread and exits having done nothing. It needs a stdin that
#      stays open, which is what "sleep infinity |" provides.
#   2. stdout buffering.  When stdout is a pipe or a file, printf is block-buffered, so killing
#      the process with timeout() throws away everything it printed. stdbuf -oL -eL forces
#      line buffering, so the log shows what happened even after a timeout kill.
#
# Usage:  ./run-ogn-rf.sh [config] [seconds]
#   config   libconfig file (default: ../config/ogn-rf-limesdr.conf)
#   seconds  stop after this many seconds (default: run until killed)
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${1:-$HERE/../config/ogn-rf-limesdr.conf}
SECS=${2:-0}
BIN=${BIN:-$HERE/../../ogn-rf/ogn-rf}

if [ ! -x "$BIN" ]; then
  echo "no ogn-rf binary at $BIN - build it first with ./build-ogn-rf.sh" >&2
  exit 1
fi
if [ ! -r "$CONF" ]; then
  echo "cannot read config $CONF" >&2
  exit 1
fi

echo "config  : $CONF"
echo "binary  : $BIN"
grep -E "^[[:space:]]*(DeviceType|DeviceSerial|Gain|SampleRate)[[:space:]]*=" "$CONF" | sed 's/^/  /'

# The stdin producer is what keeps ogn-rf alive, so a bounded run needs a bounded producer,
# not "sleep infinity | timeout N ...": the pipeline would never return, because sleep does
# not care that the receiver has exited. Letting stdin close after N seconds makes ogn-rf
# leave its command loop and shut down in its own time.
if [ "$SECS" -gt 0 ]; then
  echo "running for ${SECS}s (stdin closes after that, which is how ogn-rf exits)"
  sleep "$SECS" | stdbuf -oL -eL "$BIN" "$CONF"
  echo "[ogn-rf exited]"
else
  echo "running until interrupted"
  sleep infinity | stdbuf -oL -eL "$BIN" "$CONF"
fi
