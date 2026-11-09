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

Rough effort: build time is dominated by LimeSuite (the big library) — order of 10–20 minutes at
`-j4` on this Jetson is my estimate, unverified; plus verification. Call it an afternoon including
re-testing, not including anything physical.

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

## Open questions to settle before committing

1. Does LimeSuite 23.11 build here at all, and does its SoapyLMS7 module load into SoapySDR 0.8.1?
2. Does the reception baseline survive (throughput, scaling, calibration behaviour)?
3. Does `setClockSource("external")` do anything observable with **no** reference attached — and does
   it fail cleanly rather than quietly breaking reception? This matters: it should be testable
   *before* buying hardware.
4. What external reference rate does this board accept through `SetClockFreq(LMS_CLOCK_EXTREF, …)`,
   and is the input physically accessible (u.FL) on this revision?

## The cheaper option, for comparison

Do nothing, and note that the VCTCXO is already ±1 ppm initial and ±4 ppm over temperature and
ageing — roughly ±0.9 to ±3.5 kHz at 868 MHz, against OGN channels 200 kHz wide. `ogn-rf` also has a
GSM frequency-calibration loop that measures and corrects residual ppm; it is disabled today
(`RF.GSM.CenterFreq = 0`). Enabling it is free, but note it would need an LNA path covering
925–960 MHz — the backend selects `LNAL` (0.7–0.9 GHz) for anything under 1500 MHz, and the antenna
is cut for 868 — so that route needs its own check and probably its own antenna.

Worth deciding what the accuracy target is before doing either: reception is unlikely to be
sensitive to a few kHz, so this is a refinement rather than a prerequisite.
