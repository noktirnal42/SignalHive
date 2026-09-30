# SignalHive Radio Workshop Feature Map

Date: 2026-09-29. Status: research-backed implementation map.

SignalHive's product direction is a native Swift radio workshop. External radio projects are references, test
oracles, and UX inspiration only; implementation should stay original Swift where feasible.

## Researched Reference Points

- NOAA Weather Radio uses seven VHF public-service channels: 162.400, 162.425, 162.450, 162.475, 162.500,
  162.525, and 162.550 MHz. This justifies the starter scan bank and a weather preset workflow.
  Sources: [NWS Marine NWR frequencies](https://preview.weather.gov/marine/wxradio),
  [NWS NOAA Weather Radio test page](https://www.weather.gov/nwr/info/nwrtest.html).
- GOES HRIT/EMWIN reception is centered at 1694.1 MHz and needs different antenna/filter expectations than a
  handheld VHF scanner flow. This belongs in a satellite workspace, not the basic Scanner.
  Sources: [NOAA HRIT reception](https://www.noaasis.noaa.gov/GOES/HRIT/reception.html),
  [NOAA OSPO HRIT](https://prod-east-ospo.woc.noaa.gov/operations/goes/hrit/index.html).
- 978 MHz UAT is a distinct ADS-B weather/data path. dump978 pipelines receive 978 MHz IQ, decode UAT, and expose
  text/JSON or translate to ES/NT-style output. SignalHive should implement a Swift UAT receiver view with sample
  fixtures, not shell out as the permanent path. Source: [ADSBexchange dump978](https://github.com/ADSBexchange/dump978).
- 1090 MHz ADS-B workflows generally produce aircraft state plus network outputs for feeders/maps. SignalHive
  already has ADS-B decoder types; the app needs an ADS-B screen with live aircraft rows/map and Beast/AVR export
  later. Sources: [FlightAware PiAware/dump1090 install](https://www.flightaware.com/adsb/piaware/install),
  [FlightAware receiver streaming](https://support.flightaware.com/hc/en-us/articles/37944925213975-Streaming-Data-from-your-ADS-B-Receiver).
- rtl_433 demonstrates the breadth of ISM sensor decoding and a useful protocol-discovery workflow. SignalHive
  should model this as an IoT/ISM lab: capture, pulse analysis, decoder templates, and Swift protocol modules.
  Source: [rtl_433 README](https://github.com/merbanan/rtl_433/blob/master/README.md).
- Bluetooth work should use Core Bluetooth for BLE discovery/control rather than SDR capture. This is an adjacent
  hardware lab, not an RTL-SDR demodulator. Source: [Apple Core Bluetooth](https://developer.apple.com/documentation/corebluetooth).

## Product Slices

### Scanner

Now implemented as the main live RTL-SDR workspace:

- Direct USB RTL-SDR source selection.
- Live spectrum and waterfall.
- Frequency entry, stepping, click-to-tune, NFM/AM/WFM/SSB/CW/RAW modes.
- Noise-floor-aware activity detection in the current passband.
- Activity log with tune, hold, skip, lockout, and save-to-codeplug.
- Starter scan bank for weather, airband guard, marine 16, public-safety VHF, and GMRS.

Next scanner work:

- True multi-hop scan engine UI over counties/bands using `RTLSDRScan.BandScanner`.
- FCC-backed scan-list builder: county/service -> `ScanList`.
- Persist scan lists and lockouts in `UserDatabase`.
- Identification: activity hit -> FCC license/frequency metadata.
- Squelch/audio QA with antenna and real local signals.

### Decoder Hub

First useful decoder surfaces:

- ADS-B 1090: aircraft table/map, ICAO history, export network ports later.
- UAT 978: FIS-B/weather products, traffic, station status.
- ACARS/AIS/Morse/paging: text event stream, confidence, recording snippets.
- IoT/ISM: rtl_433-style pulse exploration and protocol modules.

### Satellite / Weather

Separate workspaces because the hardware and UX differ:

- NOAA APT: pass planner, Doppler helper, WFM audio capture, image renderer.
- Meteor LRPT: QPSK demod/deframer/image products.
- GOES HRIT: L-band setup checklist, bias tee/LNA/filter notes, image file browser.

### Hardware Lab

- rtl_tcp server/client: consume the new SwiftRTLSDR server library for Mac/Pi workflows.
- EEPROM/serial provisioning: expose only with confirmations and backups.
- Gain guard / AGC: wire SwiftRTLSDR host gain control into the live Scanner controls.
- BLE: Core Bluetooth discovery/control for accessories.
- Serial: radio programming, GPS, ESP32/Arduino/Raspberry Pi control.

### AI / ML

Useful RF-specific features:

- Signal identifier: Core ML classifier over spectrum/waterfall snippets.
- RF coach: Foundation Models explain a selected signal, likely mode, FCC/license context, and next actions.
- Session reports: summarize scan hits, saved channels, aircraft/weather events, and unresolved signals.
- Codeplug assistant: check duplicate channels, unsafe offsets, mode mismatches, and naming consistency.
- MLX model manager: keep compatibility labels tied to local memory/chip profile and annotate "works well",
  "may work", and "poor fit".
