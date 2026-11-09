#!/bin/bash
# Build ogn-rf with the LimeSDR backend on the XavierAGX (or any host with SoapySDR).
#
# Two things are unusual compared to a plain "make":
#
#  * libconfig and librtlsdr are not available as Ubuntu packages here, so they come from a
#    local prefix that the KrakenSDR work built (see PROJ below). Point PREFIX elsewhere if
#    you have them installed system-wide.
#  * FLAGS and LIBS are passed on the make command line, which OVERRIDES the Makefile's own
#    FLAGS. The Makefile therefore keeps -DUSE_LIMESDR and -lSoapySDR in separate variables
#    (SDR_FLAGS / LIME_LIBS) that survive an override; if you add flags here, do not expect
#    the Makefile's -DUSE_LIMESDR to be added for you.
#
# Usage:  ./build-ogn-rf.sh [source-tree] [output-name]
#   source-tree  the ogn-rf checkout (default: ../ogn-rf, sibling of the limesdr repo)
#   output-name  name for the binary  (default: ogn-rf)
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../ogn-rf}
OUT=${2:-ogn-rf}

# Where libconfig / librtlsdr headers and libs live
PREFIX=${PREFIX:-$HOME/projects/KrakenSDR/krakensdr/deps/prefix}

if [ ! -d "$SRC" ]; then
  echo "no source tree at $SRC" >&2
  echo "(clone it first:  git clone https://github.com/thread3d/ogn-rf.git $SRC && (cd $SRC && git checkout limesdr))" >&2
  exit 1
fi

if [ ! -f /usr/include/SoapySDR/Device.hpp ]; then
  echo "SoapySDR development headers are missing:  sudo apt install libsoapysdr-dev" >&2
  exit 1
fi

INCS=""
LIBS="-lpthread -lm -ljpeg -lconfig -lrt"
if [ -d "$PREFIX" ]; then
  INCS="-I$PREFIX/include"
  LIBS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib $LIBS"
else
  echo "warning: $PREFIX not found - hoping libconfig and librtlsdr are system-wide" >&2
fi

echo "source  : $SRC"
echo "prefix  : $PREFIX"
echo "output  : $OUT"

cd "$SRC" || exit 1
exec make USE_LIMESDR=1 \
     FLAGS="-Wall -O3 -ffast-math -DVERSION=0.2.6 $INCS" \
     LIBS="$LIBS" \
     "$OUT"
