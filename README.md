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
| Sustained sample rate | **100.1 %** of real time at 1 MSps, **100.4 %** at 2 MSps, zero overruns |
| ogn-rf time-slot acquisition and HTTP status page | **verified** — runs indefinitely, reports the LimeSDR |
| Antenna (868 MHz omni on RX1_L) | **working** — floor 17–20 dB higher at busy bands than at 868 |
| Best gain for 868 MHz | **61 dB** (top of range); at 50 dB the receiver was on its own converter floor |
| On-chip decimation (`RF.Oversample`) | defaults to the highest meaningful ratio (32); measured **no effect** on this LimeSuite build |
| Both RX channels | work simultaneously (2 × 2 MSps = 4.0 MSps, exactly at the link ceiling) but add nothing for 868 MHz OGN |
| Frequency hopping | **none in Europe** — both channels sit inside one window at a fixed 868.300 MHz |
| **Live OGN packet decoding** | **not yet** — the 868 MHz band is quiet; no transmitter audible at this location |

The chain is verified end to end. What is still missing is an OGN transmitter in range: with the
antenna connected, both OGN channels sit at the noise floor (+0.4 dB and +0.3 dB), so there is
nothing to demodulate yet. That is the nature of OGN rather than a fault — see
[`docs/hardware.md`](docs/hardware.md) for the spectrum, and
[`scripts/verify-reception.sh`](scripts/verify-reception.sh) to re-check later.

Decimation was investigated on request. A native 1 MSps capture and a 4 MSps capture decimated to
the same rate have the same in-band noise density (−88.1 vs −88.9 dBFS/Hz), because the receiver is
limited by antenna noise rather than converter resolution — so there is no SNR to win. The device's
own knob (`OVERSAMPLING`) also turns out to be a no-op on this LimeSuite build: every ratio from 0
to 4096 produces identical output. `RF.Oversample` is still set to the highest meaningful ratio
(32) as the correct configuration wherever the knob does take effect, and falls back to auto if a
device cannot deliver the rate with it.

## Quick start

```bash
# 1. build ogn-rf with the LimeSDR backend (needs the limesdr branch checked out)
git clone https://github.com/thread3d/ogn-rf.git ~/projects/LimeSDR/ogn-rf
cd ~/projects/LimeSDR/ogn-rf && git checkout limesdr
~/projects/LimeSDR/limesdr/scripts/build-ogn-rf.sh

# 2. look at the radio on its own - no ogn-rf involved
~/projects/LimeSDR/limesdr/scripts/probe-limesdr.sh --sweep
~/projects/LimeSDR/limesdr/scripts/spectrum-limesdr.sh 868.3    # what is on the air

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
│   ├── probe-limesdr.sh           SoapySDR probe, gain sweep, per-LNA-path, frequency scan
│   ├── spectrum-limesdr.sh        what is on the air at a given frequency
│   └── verify-reception.sh        is anything actually being received?
├── src/
│   └── limesdr_probe.cc           standalone receive checker (SoapySDR only, no ogn-rf)
└── tools/
    └── spectrum.py                averaged periodogram for the captured I/Q
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
| Host rate used | **2 MSps** — the ceiling `ogn-decode` accepts; ~2× headroom on the link |
| Converter ceiling | 61.44 MSps (chip) / 65 MSps advertised / **~4.1 MSps sustained on USB 2.0** |
| Tuning error at 868.300 MHz | 2 Hz |
| Noise floor at 868.3 MHz, 61 dB gain | −64 dBFS per 244 Hz bin (−88 dBFS/Hz) |
| Noise floor at 800 MHz (LTE800), same gain | −50 dBFS per ~1 kHz bin — **17 dB louder** |
| DC/LO spur at the tuned centre | −32 dBFS, 100 kHz from each OGN channel |

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
