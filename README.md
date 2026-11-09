# LimeSDR on the XavierAGX — OGN receiver backend

Working repository for getting a **LimeSDR-USB** (LMS7002M) to act as the radio for
[`ogn-rf`](https://github.com/thread3d/ogn-rf), the Open Glider Network RF front end. It holds the
tooling, the measurements and the notes; the source changes themselves live in the `limesdr`
branch of the ogn-rf repository.

Hardware: a LimeSDR-USB plugged into `xavieragx.local` (Jetson AGX Xavier, aarch64, Ubuntu 20.04).
Target use: receive the European OGN channels at 868.200 / 868.400 MHz.

## Status

| Item | State |
|---|---|
| LimeSDR backend for ogn-rf (`limesdr` branch) | **works** — opens, tunes, streams, converted I/Q verified |
| Device open / tune / gain / antenna path | **verified** on hardware |
| CS16 → 8-bit I/Q conversion scale | **verified** against a full-scale digital test tone |
| Sustained sample rate at 1 MSps | **100.1 % of real time**, zero overruns |
| ogn-rf time-slot acquisition and HTTP status page | **verified** — runs indefinitely, reports the LimeSDR |
| **Live OGN packet decoding** | **not yet** — no antenna/RF source is connected to the board |

The one thing not demonstrated is actual over-the-air OGN reception, and that is a hardware fact,
not a software one: every LNA path on the board measures the same noise floor, including at 100 MHz
where an attached antenna would show broadcast FM at enormous amplitude. See
[`docs/hardware.md`](docs/hardware.md) for the measurement. Attach an antenna and
[`scripts/verify-reception.sh`](scripts/verify-reception.sh) will tell you within a minute whether
packets are arriving.

## Quick start

```bash
# 1. build ogn-rf with the LimeSDR backend (needs the limesdr branch checked out)
git clone https://github.com/thread3d/ogn-rf.git ~/projects/LimeSDR/ogn-rf
cd ~/projects/LimeSDR/ogn-rf && git checkout limesdr
~/projects/LimeSDR/limesdr/scripts/build-ogn-rf.sh

# 2. look at the radio on its own - no ogn-rf involved
~/projects/LimeSDR/limesdr/scripts/probe-limesdr.sh --sweep

# 3. run the receiver
~/projects/LimeSDR/limesdr/scripts/run-ogn-rf.sh ~/projects/LimeSDR/limesdr/config/ogn-rf-limesdr.conf
# then browse to http://xavieragx.local:8095/
```

## What is in here

```
limesdr/
├── README.md                      this file
├── config/
│   └── ogn-rf-limesdr.conf        ogn-rf configuration for the LimeSDR
├── docs/
│   ├── hardware.md                the board, what it can do, and the measurements behind that
│   └── ogn-rf-integration.md      how the backend is wired in, and how to verify it
├── scripts/
│   ├── build-ogn-rf.sh            build ogn-rf with USE_LIMESDR
│   ├── run-ogn-rf.sh              run it (handles the two traps that make it look dead)
│   ├── probe-limesdr.sh           SoapySDR probe, gain sweep, noise-floor check
│   └── verify-reception.sh        is anything actually being received?
└── src/
    └── limesdr_probe.cc           standalone receive checker (SoapySDR only, no ogn-rf)
```

## Key numbers

Measured on this board, this gateware, this USB port — the details are in
[`docs/hardware.md`](docs/hardware.md):

| Quantity | Value |
|---|---|
| Device | LimeSDR-USB, serial `00090726074D1731`, hardware v4, firmware 4, gateware 2.23 |
| USB link | **USB 2.0** (not 3.0) |
| Reference clock | 30.72 MHz |
| Native stream format | CS16 (LMS7002M is 12-bit; full-scale 32767) |
| Gain range | −12 … +61 dB |
| Sustained streaming, USB 2.0 | **~4.1 MSps** ceiling; 1 / 2 / 4 MSps run at ~100 % of real time |
| OGN requirement | 1 MSps → about 4× headroom |
| Tuning error at 868.300 MHz | 2 Hz |

## The conversion, in one line

ogn-rf expects the interleaved 8-bit unsigned I/Q that librtlsdr produces, with 128 as zero. The
LMS7002M hands over CS16, so the backend does

```c
u8 = (int16 >> 8) + 128;      // then clamp to 0..255
```

The `>> 8` is not a guess: with the LMS7002M's own TSG_NCO digital test signal enabled the raw
words reach ±25472, and the converted bytes then span 42…227 with 53 counts of standard deviation
and no clipping. A `>> 4` would overflow; a `>> 12` would throw away the signal.

## Related

- `ogn-rf` with the LimeSDR backend: branch **`limesdr`** of
  [thread3d/ogn-rf](https://github.com/thread3d/ogn-rf) — see `docs/limesdr.md` in that branch.
- The sibling KrakenSDR work (five coherent RTL-SDRs, branch `krakensdr`) established much of the
  host configuration this leans on, including the FFTW planning fix that the `limesdr` branch
  carries as well.
- Device drivers and gateware: [myriadrf](https://github.com/myriadrf) — LimeSuite, LimeSDR-USB
  gateware.
