# SignalHive Originalization Plan

Date: 2026-09-29. Owner direction: refactor every external library, decoder, demodulator and driver into **original
Swift code**, using the external code only as inspiration and reference.

## 1. Rules

1. **Spec first.** The primary sources are standards and datasheets (TIA-102 for P25, ETSI TS 102 361 for DMR,
   ICAO Annex 10 / RTCA DO-260 for ADS-B, ITU-R M.1371 for AIS, ARINC 618 for ACARS, POCSAG/FLEX publications, USB
   class specs). External projects are read to understand behaviour and edge cases, not copied.
2. **Original structure.** No copy-paste or line-by-line transliteration. Own naming, own architecture, pure
   functions and small units that are testable without hardware.
3. **Reference tools become test oracles, not dependencies.** They are never shipped. We record IQ, run our decoder
   and the reference tool on the same capture, and compare (golden files).
4. **Provenance is written down.** Each original module gets a header: what it was written from, what it was
   cross-checked against, and what is deliberately different.
5. **Legal points are flagged, not decided by code.** In particular the voice vocoders (IMBE/AMBE) carry patent
   notices; the owner must decide before any replacement ships.
6. **Everything replaced is deleted.** When an original module passes its tests, the adapter, dylib loader and
   external source it replaces are removed in the same change.

## 2. Inventory of external code in the repository (verified 2026-09-29)

| Kind | Item | What uses it | Licence / note | Replacement |
|---|---|---|---|---|
| Compiled-in C source | `CMbelib` (mbelib: IMBE/AMBE vocoder tables and ECC; about 6,400 lines of C and headers) | `Voice/P25VoiceDecoder.swift` | ISC licence; patent notice on IMBE/AMBE | Original Swift vocoder **last**, after a legal decision (see 4, step 8) |
| Runtime-loaded library | `librtlsdr` (+ `libusb`) | `HAL/Drivers/RTLSDRDriver.swift` | GPL | Native Swift driver over Apple's USB API (step 1) |
| Runtime-loaded library | `libhackrf` | `HackRFDriver.swift` | GPL | Native driver when hardware is available (step 6) |
| Runtime-loaded library | `libairspy` | `AirspyDevice.swift` | BSD | Native driver (step 6) |
| Runtime-loaded library | `LimeSuite` | `LimeSDRDevice.swift` | Apache-2.0 | Native driver (step 6) |
| Runtime-loaded library | `libiio` | `PlutoSDRDevice.swift` | LGPL | Native driver (step 6) |
| Runtime-loaded library | `libsdrplay_api` | `SDRPlayDevice.swift` | Proprietary vendor SDK, no public protocol | Cannot be replaced without vendor documentation; keep as an optional plug-in or drop |
| External executable | `multimon-ng` | `DecoderToolPresets.pagingImageMultimonNG` | GPL | Original POCSAG/FLEX/AFSK demodulator (step 3) |
| External executable | `dsdccx` | `DecoderToolPresets.digitalVoiceDSDcc` | GPL | Original P25/DMR/NXDN/D-STAR control and metadata decoding (steps 2 and 5) |
| Online service | OpenMHz | `Data/OpenMHzClient.swift` | Returns HTTP 403 (Cloudflare challenge) to programs, so it does not work | Own trunking by decoding control channels (step 2) |
| Swift packages | GRDB, ZIPFoundation | `Data/*` | MIT; general infrastructure, not radio code | Keep unless the owner wants zero dependencies |
| Provenance comments | `ADSBDecoder` header says "Bridges to libmodes"; `UATDecoder` mentions a dump978 bridge | those files | Need checking: the ADS-B decoder is a native implementation, so the comment may be stale | Audit and correct (step 4) |

## 3. Why the RTL-SDR driver is first

- It is the owner's hardware (a local USB dongle).
- It is also the reason the radio features fail in the signed build: the sandboxed, hardened app cannot load
  Homebrew's `librtlsdr` (verified: the signed build shows one source, the Test Signal, where the unsigned build
  shows two). A native driver needs only the `com.apple.security.device.usb` entitlement the app already has,
  and no Homebrew.
- The dongle is attached, so every step can be validated on real hardware and cross-checked against `rtl_sdr`.

## 4. Order and acceptance criteria

1. **Native RTL-SDR driver (RTL2832U + R820T/R820T2/R828D).** Enumerate, open, set sample rate, frequency, gain
   (manual/auto), PPM, bias-T where supported, stream 8-bit IQ. Written from the USB descriptors, the RTL2832U
   register model and tuner behaviour, validated against reference captures.
   *Accepts when:* the signed, sandboxed app lists the dongle and streams; a capture at a fixed frequency has the
   same noise floor, DC-spike position and tuning accuracy as `rtl_sdr` within tolerance; no dlopen remains for RTL.
2. **Scanner engine and P25 Phase 1 trunking** (control channel: C4FM symbol recovery, frame sync, NID/NAC,
   TSBK decode, channel grants, identifier updates, system status). Replaces OpenMHz.
   *Accepts when:* synthetic and recorded control-channel captures decode to the expected grants, and the scanner
   follows a grant to a voice channel.
3. **Paging (POCSAG 512/1200/2400, FLEX)** replacing multimon-ng. *Accepts when:* golden recordings decode
   identically to the reference output.
4. **ADS-B, UAT, ACARS, AIS audit:** confirm these are original, correct stale comments, add golden-IQ tests.
5. **DMR, NXDN, D-STAR** control and metadata decoding replacing dsdccx.
6. **Other SDR drivers** (HackRF, Airspy, Lime, Pluto) as native drivers when the hardware is available to test.
7. **Weather satellite and other new decoders** (NOAA APT, Meteor LRPT, ...) are written original from the start.
8. **Voice vocoders (IMBE/AMBE)** replacing mbelib, only after the owner's legal decision on the patent notice.

## 5. What is already original (do not redo)

The FCC data foundation (pack builder, stores), the FFT/waterfall/scale/throttle/volume code, the FIR designer and
channelizer, the demodulators (AM, NFM, WFM, SSB, CW), and the ADS-B, ACARS, AIS and Morse decoders (pending the
audit in step 4) are written in Swift in this repository.
