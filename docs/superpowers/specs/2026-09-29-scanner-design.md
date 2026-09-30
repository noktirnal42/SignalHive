# SignalHive Scanner — Design

Date: 2026-09-29. Status: approved direction (owner: "works like a regular police/radio scanner: quickly scan, find,
identify frequencies that can be picked up; include trunking and other common systems and decoders; users can save
channels"). Hardware: local USB RTL-SDR.

## 1. What the Scanner is

A real scanner: it sweeps a list of channels (or a band) quickly, stops on activity, tells you **who** it is,
lets you hold / skip / lock out, and lets you **save** what you like into scan lists. It is not a raw SDR viewer;
the spectrum and waterfall support it.

## 2. Findings that shape the design (verified 2026-09-29)

- The Scanner streams from the RTL-SDR and from the Test Signal source.
- `FFTProcessor` returns only `fftSize/2` bins of a *complex* FFT, discarding the lower half of the band and
  putting the centre at the edge. `FrequencyFinder` already assumes the correct layout (full shifted spectrum,
  centre at bin `n/2`, `binHz = sampleRate / n`), so today it reports wrong frequencies.
- The waterfall state is never fed. There is no way to type or step a frequency.
- The dongle was configured in direct-sampling mode (fixed).
- librtlsdr's own `rtl_power` sees no FM stations on the owner's dongle: probably no antenna attached.

## 3. How a fast RTL-SDR scanner works (the algorithm)

One tuner setting captures about 2 MHz. So instead of retuning per channel, **channelized scanning**:

1. Group the channels into tuner blocks whose channels all fit inside the usable bandwidth (about 80% of the
   sample rate, avoiding the edges and the DC spike).
2. For each block: tune, wait for the tuner to settle, average the FFT for a short dwell, and read the power of
   every channel in that block from the FFT bins (sum the bins across the channel bandwidth).
3. Estimate the noise floor per block (median of the non-channel bins) and call a channel **active** when its
   power exceeds the floor by a threshold, with hysteresis so it does not flicker.
4. On activity, **hold**: tune the channel to the centre (offset to avoid the DC spike), demodulate, apply squelch
   with a hang time, then resume the sweep. Lockout skips a channel; hits go into an activity log.

A sweep of several hundred county frequencies is a few dozen blocks, so a full pass takes seconds.

## 4. Components (all in `SignalHiveCore/Scanner/`, UI-free and testable)

| Unit | Responsibility |
|---|---|
| `ScanChannel`, `ScanList` | Model: frequency, bandwidth, mode, name, lockout, source (FCC licence, manual, preset) |
| `ChannelPlanner` | Pure: channels -> tuner blocks for a given usable bandwidth |
| `ChannelMeter` | Pure: shifted FFT -> per-channel power dB and noise floor |
| `ActivityDetector` | Pure: threshold + hysteresis per channel |
| `ScanEngine` (actor) | Drives a `ScanReceiver` (tune + read spectrum) through the blocks; emits `ScanEvent`s (activity, hold, resume); hold/skip/lockout controls |
| `ChannelIdentifier` | Frequency (+ place) -> who: `FCCChannelIdentifier` uses `BrowseDataSource` frequency search |
| Saved channels | `UserDatabase` tables for scan lists and saved channels; "scan this county" builds a list from FCC licences; export to codeplug |
| `SpectrumHistory` | Waterfall rows for the UI |

`ScanReceiver` is a small protocol so the engine is tested with a deterministic fake that returns synthetic spectra,
and run for real with a wrapper over `SDRDevice` + `FFTProcessor`.

## 5. Sequencing

- **S1 — correct the display foundation.** `FFTProcessor` returns the full shifted spectrum for IQ; feed the
  waterfall; frequency entry and step tuning; hide meaningless zero power. Tests: tone at 0, +250 kHz, -250 kHz land
  in the right bins; `FrequencyFinder` returns the right frequencies for the same tones.
- **S2 — scan engine, identification, saved channels** (core, test-first, no UI dependence).
- **S3 — scanner UI**: scan lists, big frequency display, live activity feed showing identified names, hold / skip
  / lockout / save, sweep finder, spectrum + waterfall.
- **S4 — trunking and decoders**: system model (P25/DMR/NXDN) with control-channel following, tone/NAC detection,
  and the existing decoders (ADS-B, ACARS, AIS, paging...) as selectable "special" scan banks. Voice decoders carry
  a patent notice (mbelib), so data/control decoding comes first.

## 6. Testing

- Pure units: synthetic spectra with known peaks; planner block boundaries; detector hysteresis.
- Engine: fake receiver; assert sweep order, hold/resume, lockout, and that identification is requested.
- FFT: complex tones at known offsets.
- Hardware (cancels without a dongle): tuner path active after configure (done); a block sweep completes and the
  noise-floor estimate is finite.
- Acceptance: with an antenna attached, sweeping the FM band finds the local stations (needs an antenna).

## 7. Non-goals for now

Voice decoding of digital modes, encryption handling, remote (rtl_tcp/Pi) scanning, and scanner hardware control.
