# SignalHive

SignalHive is a native Swift radio workshop for macOS and iOS. The current focus is the macOS app: FCC ULS data
browsing, local USB RTL-SDR capture, scanner workflows, decoder plumbing, radio programming helpers, and a roadmap
for AI-assisted RF work.

## Current Shape

- FCC ULS packs can be built locally and browsed by state, county, licensee, site, and frequency.
- The macOS scanner path uses a native Swift RTL-SDR driver in `Packages/SwiftRTLSDR`; local USB RTL-SDR on the Mac
  is the primary hardware path.
- Network sources such as `rtl_tcp` and OpenWebRX remain optional source types for later Raspberry Pi field boxes.
- **Air Map** and **Air Data**: ADS-B (1090 MHz), UAT and FIS-B (978 MHz) with painted aircraft icons colored by
  altitude, altitude-gradient trails, NEXRAD radar and decoded weather/NOTAM text. See `docs/AVIATION.md`.
- Codeplug editor with radio-aware validation and CHIRP CSV in/out; Trunked browser (OpenMHz) with offline cache and
  talkgroup categories; one "Get FCC data" flow for many states; a verified, resumable Hugging Face model downloader.
- DSP, demodulator, decoder, codeplug, and AI workbench modules live in `Packages/SignalHiveCore`.
- The UI is SwiftUI with an instrument-style visual system; it still needs a deeper UX pass before it should be
  called polished.

## AI Direction

SignalHive is being designed around useful radio-specific AI jobs, not generic chat:

- Core ML signal identification from IQ windows.
- On-device Apple Foundation Model explanations for selected frequencies, licensees, scanner events, and codeplugs.
- Private Cloud Compute only for longer reports when entitlement, quota, network, and availability checks pass.
- MLX local assistants from Hugging Face models, with compatibility notes for this machine before download.
- Deterministic rules remain first-class for hardware status, scanner routing, and safety-critical radio decisions.

## Hardware Status

The native Swift RTL-SDR stack has passed unit tests and local hardware tests on one attached RTL2832U/R820T dongle.
That does not yet prove every dongle, antenna setup, gain profile, or over-the-air workflow. See:

- `docs/PROJECT_STATUS.md`
- `Packages/SwiftRTLSDR/README.md`
- `Packages/SwiftRTLSDR/HARDWARE.md`

## SwiftRTLSDR Upstream

`Packages/SwiftRTLSDR` is an embedded copy of the public driver package at
`https://github.com/noktirnal42/SwiftRTLSDR`. SignalHive should track stable `main` commits. Draft driver work,
including SwiftRTLSDR PR #1 for section 6 scanner/server/AGC features and follow-on dump1090/dump978 work, should
be pulled into SignalHive after it lands upstream and its package tests pass.

## Build

```bash
xcodegen generate
script/build_and_run.sh --verify
cd Packages/SignalHiveCore && swift test
cd ../SwiftRTLSDR && swift test
```

`project.yml` is the XcodeGen source of truth.

## License

GPL-2.0-or-later. SignalHive currently links the GPL-2.0-or-later SwiftRTLSDR package.
