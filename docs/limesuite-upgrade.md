# Scoping: upgrading LimeSuite to get an external reference clock

Why: the intention is to discipline the LimeSDR's reference so frequency accuracy stops being a
contributor to error. That needs a LimeSuite new enough to expose clock-source selection, and this
document records what that costs on *this* board — measured, not assumed.

**Headline: it is feasible, it needs no gateware flashing, and the blocker is not LimeSuite itself
but SoapySDR, which has to be rebuilt alongside it. Nothing here is committed to; this is the map.**

## What the installed software cannot do

The installed stack is LimeSuite **20.01.0** (Jan 2020) with SoapySDR **0.7.2**. It has no route to
an external reference, confirmed from both directions rather than from the version number:

```
$ ./limesdr_probe ...            # via SoapySDR
listClockSources()     -> 0 sources offered
getMasterClockRates()  -> empty, fixed master clock 80 MHz

$ strings /usr/lib/aarch64-linux-gnu/SoapySDR/modules0.7/libLMS7Support.so
  (settings keys: CALIBRATE, GFIR_LPF, OVERSAMPLING, TSG_NCO, TSP_CONST,
                  SAVE_CONFIG, LOAD_CONFIG, BBIC, RFIC)
  (no EXTREF, no reference-clock setting of any kind)
```

So neither the SoapySDR clock API nor a device setting can reach the VCTCXO on this build.

## Which LimeSuite version actually has it

Checked tag by tag in `SoapyLMS7/Settings.cpp`:

| LimeSuite | `setReferenceClockRate` | `listClockSources` | `EXTREF` |
|---|---|---|---|
| v20.01.0 (installed) | no | no | no |
| v20.10.0 | no | no | no |
| v22.09.0 | no | no | no |
| **v23.10.0** | **yes** | **yes** | **yes** |
| v23.11.0 (latest) | yes | yes | yes |

`v23.10.0` is the minimum. There it is:

```cpp
std::vector<std::string> SoapyLMS7::listClockSources() const { return {"internal", "external"}; }
void SoapyLMS7::setClockSource(const std::string &source) {
    _clockExternal = source == "external"; updateReferenceClock(); }
double SoapyLMS7::getReferenceClockRate(void) const;
void SoapyLMS7::setReferenceClockRate(const double rate);
void SoapyLMS7::updateReferenceClock() {
    lms7Device->SetClockFreq(LMS_CLOCK_EXTREF, _clockExternal ? _clockRate : 0.0); }
```

That is exactly the capability wanted, reachable through ordinary SoapySDR calls — so the backend
can pass it straight through from config.

## The real blocker: SoapySDR 0.8, not LimeSuite

`setReferenceClockRate` and `getReferenceClockRate` are **SoapySDR** virtuals, and they arrived in
SoapySDR **0.8.0**:

| SoapySDR header | `setReferenceClockRate` present |
|---|---|
| `soapy-sdr-0.7.2` (installed) | **0** occurrences |
| `soapy-sdr-0.8.0` | 3 occurrences |

So LimeSuite 23.x's SoapyLMS7 module **will not compile** against the installed 0.7.2, and 0.8 is a
different ABI: `libSoapySDR.so.0.7` → `.0.8`, modules directory `modules0.7` → `modules0.8`.
Ubuntu focal only packages 0.7.2, so SoapySDR 0.8 has to be built from source as well.

That means:

- every existing SoapySDR module on this board (`librtlsdrSupport`, airspy, bladerf, hackrf, uhd,
  osmosdr, redpitaya, remote, audio) is built for ABI 0.7 and will not load into an 0.8 runtime;
- `ogn-rf`'s LimeSDR backend links `libSoapySDR.so.0.7` and must be relinked against 0.8 (the source
  should be compatible — it is the link and ABI that change).

## Good news: no flashing, and no version risk

The scariest part of a LimeSuite upgrade is usually gateware. It does not apply here. Current
LimeSuite's expected-images table (`src/protocols/ConnectionImages.cpp`) says, for LimeSDR-USB
hardware v1.4:

```cpp
ConnectionImageEntry({LMS_DEV_LIMESDR, 4, 4, "LimeSDR-USB_HW_1.4_r4.0.img", 2, 23,
                      "LimeSDR-USB_HW_1.4_r2.23.rbf"}),
```

Expected: hardware 1.4, **firmware 4**, **gateware 2.23**.

The board reports hardware 4 / firmware 4 / gateware 2.23 — an **exact match**. Which reframes the
warning currently in the log: LimeSuite 20.01 expects gateware 2.22 and complains about 2.23,
because the *software* predates the bitstream. Upgrading removes the warning with nothing flashed.

Note also that gateware 2.24 exists upstream (2021) but current LimeSuite does not target it, so
**do not flash 2.24** — it would move the board off the combination the new software expects.

## Build feasibility on this board

| Requirement | LimeSuite 23.11 | This board |
|---|---|---|
| CMake | ≥ 3.10 | **3.16.3** ✓ |
| C++ standard | 11 | g++ **9.4.0** ✓ |
| libusb | yes | `libusb-1.0` present ✓ |
| SoapySDR for the module | **≥ 0.8.0** | 0.7.2 ✗ — must build |
| OS / glibc | — | Ubuntu 20.04.6, glibc **2.31** |

Nothing in the toolchain looks like a blocker for building either library. That is an assessment
from the declared requirements, **not** from having built it — see the open questions.

## Recommended shape: contain it in a private prefix

Do not replace the system SDR stack. Build SoapySDR 0.8.1 and LimeSuite 23.11 into a private prefix
(e.g. `~/projects/LimeSDR/deps/refclock`), with their modules in that prefix's `modules0.8`
directory, and relink only `ogn-rf` against it (rpath, as the KrakenSDR deps already do). The system
0.7 stack keeps working for everything else, and the two SoapySDR ABIs live in separate processes.

Steps, roughly:

1. Build SoapySDR 0.8.1 → `$PREFIX` (cmake, no exotic dependencies).
2. Build LimeSuite 23.11 → `$PREFIX`, SoapyLMS7 enabled, GUI/LimeUtil disabled (avoids wxWidgets and
   the flashing tools we do not want).
3. Relink `ogn-rf` against `$PREFIX` — `-I$PREFIX/include`, `-L$PREFIX/lib`, rpath.
4. **Verify reception is unchanged before anything else**: sample rate, throughput at 2 × 2 MSps,
   the CS16→8-bit statistics (mean ≈ 127.5, no clipping), and that `listClockSources()` now returns
   `internal`/`external`.
5. Only then add `RF.ClockSource` and `RF.ReferenceRate` to the `limesdr` branch, and re-measure
   accuracy with a disciplined source attached.

Rough effort: the spike took **about 4 minutes** to build both libraries at `-j4` — far less than
my earlier 10–20 minute estimate, which was wrong in the encouraging direction. The real work is the
verification and the config plumbing, not the compile.

## Risks

- **Behaviour drift in the new driver.** LimeSuite 23.11 may distribute gain differently, calibrate
  differently, or handle oversampling differently. The measured baseline in `hardware.md` (gain 61 dB,
  mean 127.5, no clipping, 100.4 % of real time at 2 MSps) is what makes this checkable — if those
  numbers move, stop and investigate before attributing anything to the clock.
- **Two ABIs on one machine.** Containment is the mitigation, but a stray `LD_LIBRARY_PATH` or a
  missing rpath is exactly the kind of thing that produces confusing failures. Check `ldd` on the
  rebuilt `ogn-rf`.
- **Gain semantics.** `ENABLE_NEW_GAIN_BEHAVIOUR` defaults off; do not turn it on as part of this.
- **Unbuilt.** The build has not been attempted, so "it compiles on falcon" is an inference from
  declared requirements and the available toolchain, not a result.

## Spike results — it builds and works, with one important warning

The build was carried out in a private prefix (`~/projects/LimeSDR/deps/refclock`), leaving the
system 0.7 stack completely untouched. Everything below was measured, not inferred.

### It builds (and quickly)

```
SoapySDR   0.8.1  -> $PREFIX, ABI v0.8
LimeSuite 23.11.0 -> $PREFIX, module libLMS7Support.so (23.11.0) in lib/SoapySDR/modules0.8
Total elapsed: about 4 minutes at -j4 (I had estimated 10-20; it is much cheaper than that).
```

The new stack finds the radio:

```
$ LD_LIBRARY_PATH=$PREFIX/lib $PREFIX/bin/SoapySDRUtil --info
  Lib Version: v0.8.1-unknown     ABI Version: v0.8
  Search path: .../refclock/lib/SoapySDR/modules0.8
  Module found: .../libLMS7Support.so (23.11.0)
  Available factories... lime
$ ... --find   ->   driver = lime   serial = 00090726074D1731
```

Practical note: SoapySDR's install did not bake an rpath into its own binaries, so anything run
from the prefix needs `LD_LIBRARY_PATH=$PREFIX/lib`, and anything linked against it needs
`-Wl,-rpath,$PREFIX/lib`.

### The reception baseline survives, unchanged

Same probe, same settings, built twice — once against the system stack, once against the prefix:

| Stack | mean | sd | min/max | clipping | throughput |
|---|---|---|---|---|---|
| System: SoapySDR 0.7.2 + LimeSuite 20.01 | 127.75 | 1.73 | 112–145 | 0.000 % | 100.3 % of real time |
| Prefix: SoapySDR 0.8.1 + LimeSuite 23.11 | 127.75 | 1.72 | 110–145 | 0.000 % | 100.3 % of real time |

Identical within run-to-run noise. Gain distribution, calibration behaviour and the CS16→8-bit
scaling all survive the driver upgrade at 2 MSps.

### The clock API is there — and it will lie to you

```
listClockSources      : 2  [internal] [external]
getClockSource        : 'internal'
getReferenceClockRate : 0 Hz
getReferenceClockRates: 1 range [0 .. 30720000]      <- a 10 MHz reference is in range
```

Selecting `external` **with no reference attached**:

```
setClockSource("external")  -> returned normally, no exception
getClockSource()            -> 'external'
reception                   -> mean 127.75, sd 1.81, 100.1 % of real time   (unchanged)
sensor clock_locked         -> 'true'
setReferenceClockRate(10e6)    -> accepted, reads back 10000000
setReferenceClockRate(30.72e6) -> accepted, reads back 30720000
reception                   -> unchanged for both
```

This is the answer to the question worth asking before buying hardware, and it is a **warning, not
a reassurance**. Selecting an external reference that does not exist:

- does **not** raise an error,
- does **not** disturb reception — the radio keeps working off its internal reference, and
- leaves `clock_locked` reading **`true`**.

So there is no positive confirmation anywhere that the discipline actually took effect. A receiver
configured this way looks perfectly healthy while silently running on its own VCTCXO. The only real
check is measuring absolute frequency accuracy against a known-good reference — which is the thing
the hardware was meant to provide in the first place. Plan for that measurement; do not trust
`getClockSource()` returning `'external'`.

## Open questions

1. ~~Does LimeSuite 23.11 build here, and does its SoapyLMS7 module load into SoapySDR 0.8.1?~~
   **Answered: yes.** About 4 minutes, module loads, device enumerates.
2. ~~Does the reception baseline survive?~~ **Answered: yes**, identical to within noise.
3. ~~Does `setClockSource("external")` fail cleanly with no reference attached?~~ **Answered — and
   it is subtler than "cleanly":** it succeeds silently, reception is unaffected, and `clock_locked`
   still reports `true`. No confirmation is available that it did anything.
4. **Still open:** what reference rate this board's EXTREF input actually accepts and whether the
   input is physically accessible (u.FL populated?) on this revision. Software accepts any rate up
   to 30.72 MHz; that is not evidence the connector exists or is wired. Needs a look at the board.
5. **Still open:** the real accuracy benefit, which cannot be measured without a reference to
   discipline against. This is the one thing the spike could not test.

## The cheaper option, for comparison

Do nothing, and note that the VCTCXO is already ±1 ppm initial and ±4 ppm over temperature and
ageing — roughly ±0.9 to ±3.5 kHz at 868 MHz, against OGN channels 200 kHz wide. `ogn-rf` also has a
GSM frequency-calibration loop that measures and corrects residual ppm; it is disabled today
(`RF.GSM.CenterFreq = 0`). Enabling it is free, but note it would need an LNA path covering
925–960 MHz — the backend selects `LNAL` (0.7–0.9 GHz) for anything under 1500 MHz, and the antenna
is cut for 868 — so that route needs its own check and probably its own antenna.

Worth deciding what the accuracy target is before doing either: reception is unlikely to be
sensitive to a few kHz, so this is a refinement rather than a prerequisite.
