# The LimeSDR-USB on this board — measured facts

Everything here was measured on `xavieragx` (Jetson AGX Xavier, aarch64, Ubuntu 20.04.6, kernel
5.10.104-tegra) with the LimeSDR-USB plugged into the USB hub on bus 001. Numbers are quoted with
the command that produced them so they can be re-checked.

## The device

```
$ lsusb | grep -i lime
Bus 001 Device 009: ID 1d50:6108 OpenMoko, Inc. Myriad-RF LimeSDR

$ lsusb -v -d 1d50:6108 | grep -E "bcdUSB|iProduct|bNumInterfaces|MaxPower"
  bcdUSB               2.10
  iManufacturer           1 Myriad-RF
  iProduct                2 LimeSDR-USB
  bNumInterfaces          1
  MaxPower              100mA
```

| Field | Value |
|---|---|
| Product | LimeSDR-USB (LMS7002M transceiver) |
| USB ID | `1d50:6108` |
| Serial | `00090726074D1731` (board serial `0x90726074d1731`) |
| Hardware version | 4 |
| FX3 firmware | 4 |
| Gateware | 2.23 |
| Reference clock | 30.72 MHz internal |
| USB link | **USB 2.0** — the device sits behind a USB 2.1 hub on a USB 2.0 root port |

### It is on USB 2.0, not 3.0

`SoapySDRUtil --find` labels the device `LimeSDR-USB [USB 2.0]` and reports `media = USB 2.0`,
and `lsusb` puts it on bus 001, the `1d6b:0003`/`1d6b:0002` pair's 2.0 side. That caps the sample
rate well below the 61.44 MSps the hardware can do on USB 3 — see the throughput table below.
For OGN at 1 MSps this is irrelevant, with about 4× headroom to spare.

### Gateware is newer than LimeSuite expects

```
[WARNING] Gateware version mismatch!
  Expected gateware version 2, revision 22
  But found version 2, revision 23
```

The installed LimeSuite is 20.01, which predates gateware 2.23. Streaming works — everything in
this repository was measured with that mismatch in place — but it is worth knowing about when
something behaves oddly. Resolving it means either flashing gateware 2.22 or building a current
LimeSuite; neither was necessary here.

## Software stack present

```
libsoapysdr0.7 / libsoapysdr-dev   0.7.2-1
soapysdr0.7-module-lms7            20.01.0+dfsg-2        (the LMS7 support module)
liblimesuite20.01-1                20.01.0+dfsg-2
limesuite-udev                     20.01.0+dfsg-2
soapysdr-tools                     0.7.2-1               (SoapySDRUtil)
```

Note what is **not** installed: the LimeSuite command-line tools. There is no `LimeUtil`, so
`LimeUtil --update` / `--make` (the documented way to reflash firmware and gateware) is not
available without `apt install limesuite`. The `liblimesuite20.01-1` shared library and the
SoapyLMS7 module are present, which is all the backend needs.

## Advertised capabilities (RX channel 0)

From `SoapySDRUtil --probe="driver=lime"`, identical on RX0 and RX1:

| Property | Range |
|---|---|
| Sample rates | 0.1 … 65 MSps |
| Full gain range | −12 … +61 dB (PAD 0…52, IAMP −12…+12) |
| LNA paths (antennas) | `NONE`, `LNAH`, `LNAL`, `LNAW`, `LB1`, `LB2` |
| Filter bandwidths | 1.4 … 130 MHz |
| Stream formats | CF32, CS12, CS16 — native **CS16**, full-scale 32767 |
| Frequency | 30 … 3800 MHz (RF), ±10 MHz (baseband) |
| Channels | 2 RX, 2 TX |

The `setGain()` value is an overall figure the driver distributes over the LNA, the PAD attenuator
and the IAMP stage, which is why the 64 gain steps the backend synthesises run from −12 to +61 dB
in 1.16 dB increments rather than being a tuner gain table.

## The conversion scale — verified, not assumed

ogn-rf was written for librtlsdr, which produces interleaved **8-bit unsigned** I/Q with 128 as
zero. The LMS7002M produces 12-bit samples. SoapyLMS7 delivers them as CS16, and the question that
matters is where in the 16-bit word those 12 bits sit, because the answer decides the shift.

Rather than infer it from a weak signal, the LMS7002M's own test signal generator settles it:

```
$ ./limesdr_probe -n 200000 -g 0 -t        # -t enables TSG_NCO, the digital test tone
test signal   : TSG_NCO=4 (digital test tone ON)
raw int16     : I -21776..25472  mean    10.6   Q -21408..20864  mean   -15.2
8-bit (>>8)   : mean 127.76  sd 52.05  min  42  max 227
clipping      : 0.000% at 0, 0.000% at 255
```

A full-scale tone occupies essentially the whole int16 range, so the words are **16-bit scaled**
and `>> 8` lands on 8 bits correctly:

```c
uint8_t u8 = (int16 >> 8) + 128;   // then clamp to 0..255
```

`>> 4` would clip hard; `>> 12` would leave almost nothing. The converted tone spans 42…227 with
zero clipping, which is what a properly scaled full-scale signal should look like.

## Throughput over USB 2.0

`limesdr_probe` times the streaming loop only (not device open or calibration) and counts driver
overflows:

```
rate   1000000 : 2.996 s for 3.000 s of signal  => 1001410 samples/s (100.1% of real time)
rate   2000000 : 1.495 s for 1.500 s of signal  => 2007179 samples/s (100.4% of real time)
rate   4000000 : 0.496 s for 0.500 s of signal  => 4035653 samples/s (100.9% of real time)
rate   6000000 : 0.489 s for 0.333 s of signal  => 4091166 samples/s ( 68.2% of real time)
rate   8000000 : 0.487 s for 0.250 s of signal  => 4110834 samples/s ( 51.4% of real time)
rate  10000000 : 0.485 s for 0.200 s of signal  => 4119685 samples/s ( 41.2% of real time)
```

Read that as: everything up to 4 MSps keeps up with real time; beyond that the wall clock stops
shrinking and the device is delivering a fixed ~**4.1 MSps**. At CS16 that is 4 bytes per complex
sample, so ~16.4 MB/s — a sane figure for USB 2.0 high-speed bulk transfer once protocol overhead
is accounted for.

**OGN needs 1 MSps.** Four times headroom, zero overflows in any run.

## Tuning and rate accuracy

| Asked | Got |
|---|---|
| 868 300 000 Hz | 868 299 998 Hz (2 Hz error, 0.002 ppm) |
| 1 000 000 Sps | 1 000 000.000 Sps |
| 1 999 999 Sps | 1 999 999.981 Sps |
| 500 000 Sps | 499 999.996 Sps |

Good enough that `RF.FreqCorr` can stay at 0, and `RF.FreqRaster` can be set to 1 (no rounding) —
the 28.125 kHz raster is an RTL-SDR workaround that the LMS7002M synthesiser does not need.

## Is the antenna working? Yes

An 868 MHz omni antenna is connected to **RX1_L** (the `LNAL` path the backend selects for
anything under 1500 MHz). The way to tell that it is live is not the level at 868 MHz — that band
is quiet — but the level at frequencies that are certainly busy. Measured with a 4 MSps capture,
50 dB gain, averaged periodogram, FFT bins about 1 kHz wide:

| Frequency | What is there | Noise floor |
|---|---|---|
| 780 MHz | DVB-T2 / UHF broadcast | **−52.9 dBFS** |
| 800 MHz | LTE800 downlink | **−49.8 dBFS** |
| 868.3 MHz | OGN | **−69.6 dBFS** |

The floor is **17–20 dB higher** at the two busy frequencies. That difference is the antenna
delivering real ambient RF, and it is what an unconnected port cannot do — before the antenna was
attached every one of the five LNA paths measured the same flat floor at every frequency,
including 100 MHz, where an antenna shows broadcast FM at enormous amplitude. There is also a
sharp DC/LO spur 30 dB above the local floor at the tuned centre, which is a further sign of a
live front end.

**The 868 MHz band itself is quiet right now.** Both OGN channels sit at the noise floor
(+0.06 dB and +0.05 dB above it) — no OGN transmitter is audible at this location at this moment.
That is not a fault; OGN is a low-duty-cycle network with few transmitters, received with an omni
in a room. What this means is that the receiver and the software chain can be verified, and packet
decoding has to wait for a transmitter to be in range.

Reproduce with:

```bash
./scripts/spectrum-limesdr.sh 868.3 4        # needs the antenna to show anything interesting
```

## Gain — what it does now that there is a real input

With the antenna connected, gain behaves as it should. At 800 MHz, where there is a lot of signal:

```
gain [dB]   noise floor
     -12       -73.73 dBFS
       0       -73.00
      20       -71.77
      40       -56.41
      61       -36.87
```

From 20 dB to 61 dB the floor rises 35 dB, so the gain chain is working. The flat part at the
bottom is the receiver's own converter floor: below about 20 dB the amplified antenna noise has
not yet climbed above it.

At **868.3 MHz** the same sweep, and this is the number that matters:

```
gain [dB]   noise floor     8-bit sd
      30      -73.66 dBFS      0.43
      40      -73.55           0.43
      50      -72.92           0.49
      55      -69.65           0.69
      61      -64.24           1.33
```

At 50 dB the receiver is 0.7 dB above its own converter floor — it is listening to itself, not to
the antenna. At **61 dB** (the top of the range) it is ~9 dB above that floor, i.e. genuinely
antenna-noise limited. That is why the shipped configuration sets `RF.OGN.Gain = 61.0`; the
earlier value of 50 was chosen before an antenna existed.

The remaining headroom is not available: 61 dB is the maximum the board reports, so the only way
to get more signal out of 868 MHz would be a better antenna or an external LNA.

## Decimation and oversampling — measured, and not the lever here

The LMS7002M does not sample at the rate you ask for; it decimates internally, and SoapyLMS7 exposes
the ratio as the `OVERSAMPLING` setting ("oversampling ratio (0 - auto)"). With `OVERSAMPLING = N`
the converter runs at N × the host rate and the on-chip CIC/FIR chain decimates by N, so a request
for 1 MSps still delivers 1 MSps to the host. That is exactly the "capture higher, deliver what
ogn-rf needs" arrangement, and it is now exposed as `RF.Oversample` in ogn-rf.

It measures as **neutral on this link**, and the reason is worth stating because it tells you when
it *would* help.

**In-band noise density is invariant.** A native 1 MSps capture and a 4 MSps capture, same gain,
868.3 MHz, normalised to the same 1 Hz of bandwidth:

| Capture | Floor, as measured | Bin width | Normalised |
|---|---|---|---|
| 1 MSps native | −64.23 dBFS | 244 Hz | **−88.1 dBFS/Hz** |
| 4 MSps wide | −59.00 dBFS | 977 Hz | **−88.9 dBFS/Hz** |

They agree to 0.8 dB. Decimating the wide capture down to 1 MSps cannot change that: the noise is
already spread evenly across the band, so removing out-of-band noise does not lower the density
inside it.

**The device-side knob agrees.** At 868.3 MHz and 61 dB gain, `OVERSAMPLING` of 0, 2, 8 and 16 all
give a floor of −64.2 to −64.3 dBFS; only 4 moved it (−61.9 dBFS, with the 8-bit samples
momentarily reaching the rails, so treat that point as an outlier rather than a gain). At 30 dB
gain, where the receiver *is* sitting on its converter floor, 0, 4 and 16 give −73.63, −73.84 and
−73.65 dBFS — no change at all, which says that floor is not simple converter quantisation that
averaging can remove.

**The setting also appears to do nothing at all on this build.** Every ratio from 0 to 4096 is
accepted without complaint and produces statistically identical output — same noise floor, same
OGN channel levels, same DC spur, to within 0.1 dB:

| `OVERSAMPLING` | noise floor | 868.200 | 868.400 | DC spur |
|---|---|---|---|---|
| 0 (auto) | −62.88 dBFS | +0.39 dB | +0.30 dB | −33.79 dBFS |
| 32 | −62.86 | +0.41 | +0.30 | −34.36 |
| 128 | −62.89 | +0.22 | +0.08 | −33.86 |

A ratio of 4096 at a 1 MSps host would mean a 4 GSps converter, which the LMS7002M obviously does
not do, and it is accepted just the same. The conclusion is that LimeSuite 20.01 stores the value
and does not use it to reconfigure the converter chain here, so this is a **no-op setting on this
software build** rather than a neutral-but-working one.

**Conclusion:** decimation cannot manufacture SNR that the antenna is not delivering, and on this
LimeSuite build asking for it changes nothing measurable. `RF.Oversample` is nevertheless set to
the highest meaningful ratio (32 — the converter tops out near 61.44 MSps, so that is about as
far as a 1 MSps host rate can oversample) because that is the correct configuration wherever the
knob does take effect. If a device cannot deliver the host rate with the ratio asked for, the
backend retries once with auto rather than failing to open.

## The DC spur

There is a spur at exactly the tuned frequency: −32 to −33 dBFS at 61 dB gain, about 31 dB above
the local floor, 100 kHz away from each OGN channel. It is LO leakage / residual DC offset. Setting
`CALIBRATE` to 0, 2.5, 10 or 40 MHz moves it by less than 0.7 dB, so on this gateware it is not
something the automatic calibration removes. It does not sit in the OGN channels and ogn-rf filters
each channel separately, but it does cost about 30 dB of the converter's scale, which is why the
gain cannot simply be wound up until the OGN channel fills the 8-bit range.

## Sample rate ceiling — three different numbers

"Can it sample at 60 MSps?" has three answers depending on which limit is meant, and they matter
because only the last one applies to how this board is wired.

| Limit | Value | Evidence |
|---|---|---|
| LMS7002M converter specification | **61.44 MSps** | 2 × the 30.72 MHz reference; this is the figure the clocking is built around |
| What SoapyLMS7 advertises/allows | **0.1 – 65 MSps** | `SoapySDRUtil --probe`; 65 MSps is accepted (sets 64 999 999.7 Hz), 80 MSps fails with `setSampleRate(Rx, 0, 80 MHz) Failed` |
| What this **USB 2.0** link sustains | **~4.1 MSps** | 61.44 MSps requested → 4.07 MSps delivered, 6.6 % of real time |

So "about 60" is right as the chip figure — 61.44 MSps exactly — but configuring a rate is not the
same as sustaining one. Asked for 61.44 MSps the device accepts and then delivers 4.07 MSps, because
it is on USB 2.0. On USB 3 the picture would be different; this board has it behind a USB 2.0 hub.

### Why the host runs at 2 MSps

The chain is `ogn-rf` (open, RF acquisition) → `ogn-decode` (closed source, demodulator), and
2 MSps is the highest rate the decoder accepts. 2 MSps sits comfortably inside the ~4.1 MSps the
link sustains (measured at 100.4 % of real time), so `RF.SampleRate = 2000000` is used.

It buys margin for the demodulator, not range: the two OGN channels occupy about 250 kHz and sit at
±100 kHz around the 868.300 MHz centre, which 1 MHz already covered, and in-band noise density is
invariant with sample rate (see the decimation section). Both channels land well inside the ±1 MHz
window at 2 MSps.

Note that `ogn-decode` is not installed on this board and is not open source, so its 2 MSps limit is
taken as given rather than measured here. The rate it is sensitive to is the RF rate that scales the
Fourier spectra `ogn-rf` hands it through `ogn-rf.fifo`.

## Both receivers at once — possible, but of no use for 868 MHz OGN

The LimeSDR-USB has two RX channels, each with its own synthesiser and its own LNA paths
(`RX1_L/_H/_W` and `RX2_L/_H/_W`). Both are usable:

```
$ ./limesdr_probe -C 2 -f 868200000 -F 868400000 -r 2000000 -g 61 -n 4000000
ch0           :  868.2000 MHz  2.000 MSps  61.0 dB  LNAL
ch1           :  868.4000 MHz  2.000 MSps  61.0 dB  LNAL
stream        : 2 channels, MTU 2040 samples/ch
per channel   : 2000446 samples/s (100.0% of real time)
aggregate     : 4.00 MSps over 2 channels
```

Independent tuners is the important part: 868.200 and 868.400 MHz ran simultaneously, so they are
separate synthesisers rather than one shared LO.

### What it costs

Both channels share the one USB link, so their rates add up against the same ~4.1 MSps ceiling:

| Configuration | Aggregate | Delivered |
|---|---|---|
| 2 × 1 MSps | 2 MSps | 100.0 % of real time |
| **2 × 2 MSps** | **4 MSps** | **100.0 %**, zero overflows |
| 2 × 2.5 MSps | 5 MSps | 2.04 MSps/ch — 81.6 % |
| 2 × 3 MSps | 6 MSps | 2.04 MSps/ch — 68.0 % |

2 MSps per channel fits the link **exactly**, with nothing left over. That is the ceiling.

### Why it buys nothing here

Three measurements, each pointing the same way:

**A dedicated tuner per channel is not more sensitive — it is less.** The current approach receives
both OGN channels in one 2 MSps window centred on 868.300 MHz. The alternative would be to give each
channel its own tuner and a narrower rate. Measured, normalised to 1 Hz of bandwidth:

| Approach | Noise density |
|---|---|
| One tuner, 2 MSps, centred 868.300 | **−88.8 dBFS/Hz** |
| Dedicated tuner on 868.200, 500 ksps | **−83.9 dBFS/Hz** |

The narrow dedicated tuner is ~5 dB **worse**. Splitting the channels does not help.

**Retuning is not the bottleneck either.** A retune costs 64 ms on average (78 ms worst), measured
on 400 kHz steps across the 902 MHz band. ogn-rf retunes immediately after reading a slot and the
next slot does not start for around a second, so the cost is absorbed by the idle gap rather than
eaten out of a slot. Pre-tuning a second receiver to save it would recover nothing.

**There is nowhere for the second channel's samples to go.** `ogn-decode` is closed source and
consumes one stream; it is what `ogn-rf` writes to `ogn-rf.fifo`. A second receiver produces samples
that no decoder will read.

### Where it would earn its place

- **Hopping plans (USA/Australia).** Those plans pick a channel per time slot by hash across 25 MHz,
  so a single receiver can only cover the subset of the four hopped frequencies that falls inside one
  sample-rate window. Two tuners could cover two windows. The decoder constraint above would still
  have to be solved first.
- **Direction finding.** Two channels can be made phase-coherent, and `SoapyLMS7` even offers an
  `align phase` stream argument. This was **not** verified here: the LMS7002M's digital test tone is
  injected after the mixer, so it shows a stable zero phase regardless of the LOs, and there is no
  second antenna or splitter to present a common RF signal to both channels. Any DF work would need
  that measurement first, plus a second antenna feed.

For the European 868 MHz plan — two channels 200 kHz apart, both already inside one 2 MSps window —
using both receivers adds nothing.

## Frequency hopping — there is none in Europe, so nothing to fix

Worth being precise about, because "hopping" sounds like a problem to solve and here it is not.

The European plan (`FreqPlan = 1`) is two channels **200 kHz apart**: 868.200 and 868.400 MHz. The
plan logic alternates channel between time slot 0 and slot 1, but both of those frequencies are
inside a single capture window. `ogn-rf`'s `calcCenterFreq()` collects the four (slot × OGN/FLARM)
frequencies, sorts them, and — whenever the whole span fits inside `SampleRate − 150 kHz` — centres
on the midpoint:

```
HopFreq = { 868.2, 868.4, 868.4, 868.2 }   span 200 kHz
Band    = SampleRate - 150 kHz            = 1.85 MHz at 2 MSps, 850 kHz at 1 MSps
200 kHz < Band  =>  CenterFreq = 868.300 MHz   for every time slot
```

So the receiver tunes to 868.300 MHz once and **never retunes again**. The "hop" between slot 0 and
slot 1 is covered by receiving both channels simultaneously, at any sample rate above about
350 kHz. There is no retune to make fast, and no clock source needed to make one reliable.

### A retune that changes nothing used to cost the same as a real one

SoapyLMS7 does not skip a `setFrequency()` that would program the frequency already in use, and
`ogn-rf` calls `setCenterFreq(NextCenterFreq)` after every slot. In Europe `NextCenterFreq` is
always 868.300 MHz, so that was ~58 ms of pointless PLL re-lock and calibration on every slot.
The backend now remembers the LO it last programmed and returns immediately when it has not
changed. Measured through the backend:

| Call | Before | After |
|---|---|---|
| `setCenterFreq(868.300 MHz)` unchanged, ×10 | 567 ms | **0.00 ms** |
| `setCenterFreq(±400 kHz)` — a real retune, ×10 | 571 ms | 578 ms (57.8 ms each) |

Real retunes still cost what they cost; there are simply none to do here. That matters if you ever
do move to a plan that hops — a single retune is 58 ms against a one-second slot, and doing it from
cold leaves the receiver deaf for the start of the slot.

## A clock source: what it would and would not fix

The board's reference is a **Rakon RPT7050A 30.72 MHz VCTCXO, ±1 ppm initial and ±4 ppm over
temperature and ageing** — which at 868 MHz is roughly ±0.9 kHz to ±3.5 kHz. The LimeSDR-USB
hardware supports disciplining it ("possibility to lock VCTCXO to external clock or tune VCTCXO by
onboard DAC").

What a good external reference (GPSDO or OCXO) would buy:

- **Absolute frequency accuracy**, from ~1–4 ppm to better than 0.01 ppm. That is what `ogn-rf`'s
  GSM calibration loop exists to measure and correct; a disciplined reference makes it unnecessary.
  Currently `RF.FreqCorr = 0` and the GSM calibration is disabled (`RF.GSM.CenterFreq = 0`), so the
  receiver relies entirely on the VCTCXO's own accuracy.
- **Sample-clock accuracy**, hence tighter slot timing.
- **Phase coherence between RX0 and RX1**, if both derive from the same reference — which is the
  prerequisite for any direction-finding work with the second receiver.

What it would **not** buy:

- **Faster retuning.** The 58 ms is PLL re-lock plus the LMS7002M's automatic calibration. It is
  chip-internal and independent of reference stability.
- **Anything to do with hopping in Europe**, because there is no hopping.

### But SoapySDR cannot reach it on this build

The hardware supports an external reference; the software stack here does not expose it. Measured:

```
listClockSources()     -> 0 sources offered
getMasterClockRates()  -> empty, fixed master clock 80000000 Hz
```

The SoapyLMS7 support module in LimeSuite 20.01 offers no clock-source selection and no
master-clock control, so disciplining the VCTCXO from `ogn-rf` is not reachable through SoapySDR. It
would need either a newer LimeSuite that exposes it, or driving the VCTCXO tuning DAC directly —
both outside this backend. Worth knowing before buying a reference: the frequency accuracy win is
real, but the plumbing to use it is not present yet.

## The LNA path follows the antenna, not the datasheet

The LNA paths are band-limited — LNAL 0.7–0.9 GHz, LNAW 0.7–2.6 GHz, LNAH 2–2.6 GHz — and **each maps
to a different SMA connector**: LNAL to RX1_L, LNAW to RX1_W. With the only antenna on RX1_L, choosing
strictly by band would put 0.9–2.6 GHz on RX1_W, which has nothing attached. That fails silently,
because an unconnected port still shows the receiver's own noise floor.

This was measured the hard way: for the GSM accuracy scan at 940 MHz the backend first selected LNAW
(the datasheet-correct path) and the results were self-contradictory; on LNAL — the port the antenna
is actually on, even though it is a band low for 940 MHz — the same scan gave a clean, reproducible
+14.4 ppm. The code therefore prefers LNAL up to 1.5 GHz and notes that going beyond needs an antenna
on RX1_W or RX1_H.

## See also

- [`ogn-rf-integration.md`](ogn-rf-integration.md) — how the backend maps these facts onto ogn-rf,
  including `RF.Oversample`.
- [`../scripts/probe-limesdr.sh`](../scripts/probe-limesdr.sh) — gain sweeps, per-LNA-path checks
  and frequency scans.
- [`../tools/spectrum.py`](../tools/spectrum.py) — the averaged periodogram behind every spectral
  number above.
