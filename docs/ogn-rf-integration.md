# Wiring the LimeSDR into ogn-rf

The code lives in branch **`limesdr`** of [thread3d/ogn-rf](https://github.com/thread3d/ogn-rf).
This document explains what was changed and why, so the next person does not have to reverse it out
of the diff. Facts about the hardware itself are in [`hardware.md`](hardware.md).

## The starting point

ogn-rf talks to the radio through exactly one class, `RTLSDR` in `rtlsdr.h`, which is a thin wrapper
over `librtlsdr`. `RF_Acq` (in `ogn-rf.cc`) holds it as a plain member and calls about twenty
methods on it:

```cpp
RTLSDR SDR;
...
SDR.Open(Index, CurrCenterFreq, SampleRate);
SDR.ResetBuffer();
int Read = SDR.Read(*Buffer, SamplesToRead);
SDR.setCenterFreq(NextCenterFreq);
```

The important contract is not the API shape, it is the data: `Read()` hands back interleaved
8-bit unsigned I/Q with 128 as zero, `SampleBuffer::Rate` in samples/second and `Freq` in Hz.
Everything downstream — pulse filter, FFT, OGN demodulator, GSM calibration — consumes that and
knows nothing about where it came from.

## The approach: a dispatch layer, not a rewrite

Two new headers, and five lines changed in `ogn-rf.cc`:

| File | Role |
|---|---|
| `limesdr.h` | `LimeSDR` — a SoapySDR backend that mirrors the `RTLSDR` interface |
| `sdr.h` | `SDR_Device` — owns both backends and forwards every call to the active one |
| `ogn-rf.cc` | `RTLSDR SDR` becomes `SDR_Device SDR`; config parses `RF.DeviceType` |
| `Makefile` | auto-detects SoapySDR, adds `-DUSE_LIMESDR` and `-lSoapySDR` |

The `LimeSDR` class was written against the *same method names and semantics* as `RTLSDR`, which
means the dispatch layer is a set of one-line forwards and every existing call site in `ogn-rf.cc`
keeps reading `SDR.something(...)`. No virtual functions, no pointer indirection, no allocation at
run time — one of the two members is simply never opened.

When SoapySDR is not present at build time, `sdr.h` uses `RTLSDR` itself as an inert placeholder so
the dispatch expressions still compile and the binary is exactly an RTL-SDR build. `SDR_Device`
refuses to select the LimeSDR backend in that case.

### Why SoapySDR rather than liblimesuite

`liblimesuite20.01-1` is installed, but `liblimesuite-dev` is not, so the LMS7 API headers are
missing, while `libsoapysdr-dev` and `soapysdr0.7-module-lms7` are both present. SoapySDR is also
the interface the rest of the system already speaks, and it keeps a future second radio
(Airspy, bladeRF, a KrakenSDR behind Soapy) on the same path.

## How each RTL-SDR concept maps

| `RTLSDR` | `LimeSDR` implementation |
|---|---|
| `Open(index, freq, rate)` | `SoapySDR::Device::make()`, then rate, antenna, manual gain, tune, `setupStream(CS16)` |
| `Read(buf, samples)` | `readStream()` in MTU-sized chunks, CS16 converted to 8-bit unsigned |
| `ResetBuffer()` | `readStream()` with a zero timeout until nothing is pending |
| `setCenterFreq()` | `setFrequency()`; the freq raster is applied first, exactly as librtlsdr does |
| `setFreqCorrection(ppm)` | **software**: retunes the LO to `freq × (1 + ppm·1e-6)` |
| `getCenterFreq()` | the *nominal* frequency, i.e. before the ppm correction, so reports stay nominal |
| `setTunerGain(0.1 dB)` | `setGain()` in dB, clamped to the reported gain range |
| `getTunerGains()` | synthesised from `getGainRange()` into the same 0.1 dB table format |
| `setTunerGainMode()` | `setGainMode(automatic = Mode<=0)`, so ogn-rf's 1 means manual |
| `setBiasTee()` | **accepted and ignored** — a LimeSDR-USB has no on-board bias tee |
| `setOffsetTuning()` | **accepted and ignored** — an RTL-SDR/E4000 concept |
| `getXtalFreq()` | 30.72 MHz for both, the board's actual reference |
| `getDeviceIndexBySerial()` | matches the `serial` field of `SoapySDR::Device::enumerate()` |

Two details are deliberate rather than incidental:

**`ResetBuffer()` must not re-calibrate.** The obvious implementation — deactivate and reactivate
the stream — re-runs the LMS7002M's automatic DC/IQ calibration, which takes long enough to miss
the start of the next OGN slot, and ogn-rf calls `ResetBuffer()` before *every* slot. Draining with
a zero timeout is fast and does what ogn-rf actually wants: throw away stale buffered samples.

**The ppm correction is done in software.** The LMS7002M has no tuner crystal to trim, and
SoapySDR's `setFrequencyCorrection()` means different things to different drivers. Applying it to
the LO frequency is predictable, and it keeps `getCenterFreq()` reporting the nominal channel,
which is what ends up in the APRS report.

## The conversion

```c
int Val = (Scratch[Idx] >> 8) + 128;
if(Val < 0) Val = 0; else if(Val > 255) Val = 255;
```

with the shift justified by measurement — the LMS7002M's TSG_NCO test tone reaches ±25472 in the
CS16 words, so `>> 8` maps 16-bit words onto the 8-bit range with the same full-scale as an RTL-SDR
dongle. See [`hardware.md`](hardware.md#the-conversion-scale--verified-not-assumed).

The stream MTU on this device is **2040 samples**, so a 0.85 s OGN slot (850 000 samples) is about
417 `readStream()` calls. Overruns are counted and skipped rather than treated as fatal; timeouts
are tolerated up to 8 in a row before `Read()` gives up and lets `RF_Acq` close and reopen the
device, which is the same recovery path an RTL-SDR failure takes.

## Configuration

```c
RF = {
  DeviceType   = "limesdr";      // or "rtlsdr"; RF.SDR is accepted as an alias
  DeviceSerial = "00090726074D1731";
  FreqPlan     = 1;              // Europe/Africa: 868.200 and 868.400 MHz
  FreqRaster   = 1;              // no raster rounding - unnecessary on an LMS7002M
  SampleRate   = 1000000;
  OGN = { Gain = 50.0; GainMode = 1; SampleRate = 1000000;
          SensTime = 0.85; StartTime = 0.375; };
};
```

`RF.OGN.Gain` is in **dB** here, in the units SoapySDR reports, not an RTL-SDR tuner's discrete
gain steps — ogn-rf multiplies by 10 internally and the backend converts back. A copy of this file
is in [`../config/ogn-rf-limesdr.conf`](../config/ogn-rf-limesdr.conf).

## Building

The Makefile auto-detects SoapySDR:

```make
ifndef USE_LIMESDR
ifneq ("$(wildcard /usr/include/SoapySDR/Device.hpp)","")
USE_LIMESDR = 1
endif
endif
```

One trap is worth repeating because it fails silently: `-DUSE_LIMESDR` lives in `SDR_FLAGS`, not
`FLAGS`, because a `make FLAGS="..."` on the command line **replaces** the Makefile's `FLAGS`
entirely. Keeping the define in a separate variable means an override keeps the backend enabled;
had it been in `FLAGS`, the documented build line would have produced a binary that silently could
not select a LimeSDR at all.

## What was verified

All on the board, with the branch built and running:

| Check | Result |
|---|---|
| Build | 12.5 s, no errors; `ldd` shows `libSoapySDR.so.0.7` |
| Device opens | `LimeSDR::Open(0,868300000,1000000) => LimeSDR-USB, 868.300 MHz, 1.000 Msps, MTU=2040` |
| Gain table | 64 steps, −12.0 … +61.0 dB |
| LNA path | `LNAL` selected for 868 MHz |
| Status page | `LimeSDR device #0`, `Myriad-RF`, `LimeSDR-USB`, serial, 868.300 MHz, 1.000 MHz |
| Sample statistics through ogn-rf | mean **127.5**, sd 0.50, min 126, max 129, **no clipping** |
| Time-slot acquisition | continuous `Half time slot` / `Dropped a slot`, no read errors |
| Long run | >80 s with **zero** timeouts and zero overflow-driven failures |
| Sustained rate | 100.1 % of real time at 1 MSps |

The sample statistics were read back out of ogn-rf's own `/time-slot-rf.u8` endpoint, so they
went through `LimeSDR::Read()` and not the standalone probe. Mean 127.5 against an expected 128 is
the direct evidence that the conversion and the DC handling are right.

`Half time slot` and `Dropped a slot` in the log are **expected** and not a LimeSDR problem: with
no decoder attached nothing drains `OutQueue`, so ogn-rf halves its read window and then starts
dropping. Draining `ogn-rf.fifo` raises the reported live time immediately. The same message pair
appears on the KrakenSDR/RTL-SDR build.

## Known limitations

1. **No RF input is connected.** Every LNA path and a sweep across 100/433/868/915 MHz measure the
   same noise floor, including at 100 MHz where any antenna would show broadcast FM. Live OGN
   packet decoding therefore cannot be demonstrated on this setup. Attach an antenna and run
   [`../scripts/verify-reception.sh`](../scripts/verify-reception.sh).
2. **RX0 only.** `LimeSDR::Channel` is 0. The board has two RX channels; using both (or using them
   coherently) is not implemented, and would need the two channels started and read in lockstep.
3. **Gateware 2.23 against LimeSuite 20.01** (expects 2.22) warns at open. Working, but unexplained
   behaviour should be re-checked against a matched pair.
4. **No bias tee.** `RF.BiasTee` is accepted and ignored; powering an external LNA needs external
   hardware.
5. **GSM frequency calibration is untested.** The retune path is implemented (`setCenterFreq`,
   `setTunerGain`, `setTunerGainMode`) but with no RF at all it has never had a burst to lock to.
6. **`setFreqCorrection` is software-only** and therefore corrects the LO, not the reference
   oscillator; it is not a substitute for a GPS-disciplined reference if absolute accuracy matters.

## Runtime traps inherited from upstream

Both make a healthy ogn-rf look completely dead, and both are handled by
[`../scripts/run-ogn-rf.sh`](../scripts/run-ogn-rf.sh):

- **stdin.** `main()` breaks out of its loop when `fgets(...,stdin)` hits EOF, so stdin must stay
  open: `sleep infinity | ogn-rf ...`.
- **stdout buffering.** `printf` is block-buffered into a pipe or file, so a `timeout` kill discards
  the log; `stdbuf -oL -eL` fixes it.

The `limesdr` branch also carries the FFTW planning change from the `krakensdr` branch: `fft.h`
hard-coded `FFTW_MEASURE`, and single-precision planning on this ARM host takes 37 s (4 096 pt) to
61 s (32 768 pt) inside global constructors, before `main()`, producing no output at all. The
default is now `FFTW_ESTIMATE`, overridable with `-DFFTW_PLAN_FLAG=FFTW_MEASURE`.
