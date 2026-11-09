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

## Noise floor — and why there must be no antenna attached

Gain sweep at 868.300 MHz, manual gain, 1 M samples per step:

```
  gain [dB]   mean8    sd8    min8  max8   clip-low clip-high  raw-I[min..max]
       0.0   -0.24   0.43    127   128     0.000%     0.000%     -64..64
      10.0   -0.25   0.43    127   128     0.000%     0.000%    -224..16
      20.0   -0.27   0.46    126   128     0.000%     0.000%    -320..16
      30.0   -0.26   0.44    127   128     0.000%     0.000%    -144..32
      40.0   -0.25   0.45    125   129     0.000%     0.000%    -576..112
      50.0   -0.26   0.45    125   129     0.000%     0.000%    -384..400
      61.0   -0.28   0.86    118   133     0.000%     0.000%   -1216..1344
```

A healthy OGN receiver at 1 MSps shows roughly 10 counts of standard deviation in these 8-bit
units. This sees 0.4–0.9 — one to one-and-a-half bits of a 12-bit converter, which is what an
input with nothing on it looks like. The flattening up to 50 dB is the ADC's own quantisation
floor dominating; the noise of the signal path only rises above it at maximum gain.

Two more checks, both pointing the same way:

```
$ ./limesdr_probe -n 500000 -g 50 -A         # every LNA path in turn
  path    mean8    sd8    min8  max8   raw-I[min..max]
  LNAH    -0.25   0.44    127   129    -256..96
  LNAL    -0.27   0.48    125   129    -368..336
  LNAW    -0.24   0.45    126   130    -400..592
  LB1     -0.26   0.44    126   128    -288..80
  LB2     -0.26   0.47    126   128    -336..64
```

All five connectors measure the same. And across frequencies:

| Frequency | sd8 at 50 dB |
|---|---|
| 100 MHz (FM broadcast — loud with any antenna) | 0.60 |
| 433.920 MHz (ISM) | 0.59 |
| 868.300 MHz (OGN) | 0.50 |
| 915.000 MHz | 0.64 |

If an antenna were attached anywhere, 100 MHz would be enormous. It is not: **no RF input is
connected to the LimeSDR**. That is why live OGN decoding cannot be demonstrated on this setup yet,
and it is the first thing to fix before drawing conclusions about reception quality.

## See also

- [`ogn-rf-integration.md`](ogn-rf-integration.md) — how the backend maps these facts onto ogn-rf.
- [`../scripts/probe-limesdr.sh`](../scripts/probe-limesdr.sh) — re-run all of the above.
