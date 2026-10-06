#!/usr/bin/env python3
"""Produce the SGP4 test oracle as data: python-sgp4 output for the official verification set and a few real satellites.

SignalHive's SGP4 is original Swift written from the published equations. This script exists only to make reference
numbers to test it against; it uses the `sgp4` package through its public API and nothing from it is copied.

    python3 script/gen_sgp4_oracle.py [--weather celestrak-weather.json] > .../Fixtures/sgp4-oracle.json

Without --weather the CelesTrak weather group is fetched once (CelesTrak asks for at most one fetch per 2 hours).
The oracle is self-checked against the C++ reference output (`tcppver.out`) that ships with the package, so a wrong
operation mode or gravity constant fails here instead of in the Swift tests.
"""
import argparse
import datetime as dt
import json
import math
import os
import sys
import urllib.request

import sgp4
from sgp4.api import Satrec, WGS72, jday

PACKAGE_DIR = os.path.dirname(sgp4.__file__)
WEATHER_URL = "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=json"
WEATHER_NAMES = ("METEOR-M2 4", "METEOR-M2 3", "NOAA 21 (JPSS-2)")

# ISS elements of 2025-09-30, the set the old planner's tests used.
ISS = (
    "1 25544U 98067A   25273.56282970  .00013982  00000+0  25353-3 0  9991",
    "2 25544  51.6311 178.9253 0004254  36.7694 323.3591 15.50035835533355",
)
DEFAULT_MINUTES = [-1440.0, -360.0, 0.0, 360.0, 1440.0, 4320.0]
XPDOTP = 1440.0 / (2.0 * math.pi)


def checksum_ok(line):
    total = 0
    for ch in line[:68]:
        if ch.isdigit():
            total += int(ch)
        elif ch == "-":
            total += 1
    return total % 10 == int(line[68])


def exp_field(text):
    """TLE 'assumed decimal point' field such as ' 28098-4' or '-11606-4'."""
    text = text.strip()
    mantissa, exponent = text[:-2], text[-2:]
    sign = -1.0 if mantissa.startswith("-") else 1.0
    digits = mantissa.lstrip("+-")
    return sign * float("0." + digits) * (10.0 ** int(exponent))


def tle_epoch(line1):
    yy = int(line1[18:20])
    day = float(line1[20:32])
    year = 2000 + yy if yy < 57 else 1900 + yy
    return dt.datetime(year, 1, 1) + dt.timedelta(days=day - 1.0)


def omm_from_tle(name, line1, line2):
    epoch = tle_epoch(line1)
    return {
        "OBJECT_NAME": name,
        "NORAD_CAT_ID": int(line1[2:7]),
        "EPOCH": epoch.isoformat(timespec="microseconds"),
        "MEAN_MOTION": float(line2[52:63]),
        "ECCENTRICITY": float("0." + line2[26:33].strip()),
        "INCLINATION": float(line2[8:16]),
        "RA_OF_ASC_NODE": float(line2[17:25]),
        "ARG_OF_PERICENTER": float(line2[34:42]),
        "MEAN_ANOMALY": float(line2[43:51]),
        "BSTAR": exp_field(line1[53:61]),
        "MEAN_MOTION_DOT": float(line1[33:43]),
        "MEAN_MOTION_DDOT": exp_field(line1[44:52]),
    }


def satrec_from_omm(omm):
    """AFSPC operation mode ('a') with WGS-72, the mode of the official verification set."""
    epoch = dt.datetime.fromisoformat(omm["EPOCH"])
    jd, fr = jday(epoch.year, epoch.month, epoch.day, epoch.hour, epoch.minute,
                  epoch.second + epoch.microsecond / 1e6)
    sat = Satrec()
    d2r = math.pi / 180.0
    sat.sgp4init(
        WGS72, "a", omm["NORAD_CAT_ID"],
        jd + fr - 2433281.5,
        omm["BSTAR"],
        omm["MEAN_MOTION_DOT"] / (XPDOTP * 1440.0),
        omm["MEAN_MOTION_DDOT"] / (XPDOTP * 1440.0 * 1440.0),
        omm["ECCENTRICITY"],
        omm["ARG_OF_PERICENTER"] * d2r,
        omm["INCLINATION"] * d2r,
        omm["MEAN_ANOMALY"] * d2r,
        omm["MEAN_MOTION"] / XPDOTP,
        omm["RA_OF_ASC_NODE"] * d2r,
    )
    return sat


def times(start, stop, step):
    out, k = [], 0
    while True:
        t = start + k * step
        if t > stop + 1e-9:
            return out
        out.append(round(t, 9))
        k += 1


def thin(values, limit):
    if len(values) <= limit:
        return values
    picks = sorted({round(i * (len(values) - 1) / (limit - 1)) for i in range(limit)})
    return [values[i] for i in picks]


def propagate(sat, minutes_list):
    """Samples up to (not including) the first failure, plus that failure's (minutes, code) or None."""
    samples = []
    for t in minutes_list:
        e, r, v = sat.sgp4_tsince(t)
        if e != 0 or not all(math.isfinite(x) for x in list(r) + list(v)):
            return samples, (t, e if e != 0 else -1)
        samples.append({"minutes": t, "r": list(r), "v": list(v)})
    return samples, None


def build_case(name, omm, tle, minutes_list):
    sat = satrec_from_omm(omm)
    all_samples, failure = propagate(sat, minutes_list)
    # Thinned for the file, but the failure point is found on the full list so it is exact.
    kept = thin([s["minutes"] for s in all_samples], 12)
    by_minute = {s["minutes"]: s for s in all_samples}
    return {
        "name": name,
        "noradID": omm["NORAD_CAT_ID"],
        "omm": omm,
        "tle": list(tle) if tle else None,
        "periodMinutes": 1440.0 / omm["MEAN_MOTION"],
        "samples": [by_minute[m] for m in kept],
        "error": failure[1] if failure else None,
        "errorMinutes": failure[0] if failure else None,
    }, sat, all_samples


def verification_cases():
    path = os.path.join(PACKAGE_DIR, "SGP4-VER.TLE")
    lines = [l.rstrip("\n") for l in open(path) if l.strip() and not l.startswith("#")]
    for i in range(0, len(lines), 2):
        line1, line2 = lines[i], lines[i + 1]
        assert line1.startswith("1 ") and line2.startswith("2 "), (line1, line2)
        extra = line2[69:].split()
        tle = (line1[:69], line2[:69])
        if not checksum_ok(tle[0]) or not checksum_ok(tle[1]):
            print(f"note: verification set line has a different checksum: {tle[0][:8]}", file=sys.stderr)
        omm = omm_from_tle(f"VER-{int(line1[2:7]):05d}", *tle)
        if len(extra) == 3:
            start, stop, step = map(float, extra)
            yield omm, tle, times(start, stop, step)
        else:
            yield omm, tle, DEFAULT_MINUTES


def check_against_cpp_reference(cases_full):
    """The package ships the C++ reference output; every near-earth position there must match ours to its 8 decimals.

    Deep-space cases are reported but not enforced: SignalHive refuses them (period >= 225 min), and python-sgp4
    2.25 and the reference differ on one of them (23599) by up to about a kilometre.
    """
    path = os.path.join(PACKAGE_DIR, "tcppver.out")
    if not os.path.exists(path):
        print("note: tcppver.out not found, skipping the cross-check", file=sys.stderr)
        return
    worst = {"near": 0.0, "deep": 0.0}
    compared = {"near": 0, "deep": 0}
    current = None
    for line in open(path):
        parts = line.split()
        if len(parts) == 2 and parts[1] == "xx":
            current = cases_full.get(int(parts[0]))
            continue
        if current is None or len(parts) < 7:
            continue
        period, samples = current
        sample = samples.get(round(float(parts[0]), 6))
        if sample is None:
            continue
        kind = "near" if period < 225 else "deep"
        ref = [float(x) for x in parts[1:4]]
        worst[kind] = max(worst[kind], max(abs(a - b) for a, b in zip(ref, sample["r"])))
        compared[kind] += 1
    print(f"cross-check vs tcppver.out: near-earth {compared['near']} positions, worst {worst['near']:.2e} km; "
          f"deep-space {compared['deep']} positions, worst {worst['deep']:.2e} km (not enforced)", file=sys.stderr)
    if compared["near"] < 100 or worst["near"] > 2e-8:
        sys.exit("oracle does not reproduce the official reference output; check opsmode and constants")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weather", help="saved CelesTrak weather group JSON (skips the network fetch)")
    args = parser.parse_args()

    cases, full_samples = [], {}
    for omm, tle, minutes in verification_cases():
        case, _, all_samples = build_case(omm["OBJECT_NAME"].lower(), omm, tle, minutes)
        cases.append(case)
        full_samples[omm["NORAD_CAT_ID"]] = (case["periodMinutes"], {round(s["minutes"], 6): s for s in all_samples})
    check_against_cpp_reference(full_samples)

    iss_omm = omm_from_tle("ISS (ZARYA)", *ISS)
    cases.append(build_case("iss-2025-09-30", iss_omm, ISS, DEFAULT_MINUTES)[0])

    if args.weather:
        weather = json.load(open(args.weather))
    else:
        weather = json.load(urllib.request.urlopen(WEATHER_URL, timeout=60))
    wanted = {w: None for w in WEATHER_NAMES}
    for entry in weather:
        if entry["OBJECT_NAME"] in wanted:
            wanted[entry["OBJECT_NAME"]] = entry
    for name, entry in wanted.items():
        if entry is None:
            sys.exit(f"{name} is not in the weather group")
        omm = {k: entry[k] for k in ("OBJECT_NAME", "NORAD_CAT_ID", "EPOCH", "MEAN_MOTION", "ECCENTRICITY",
                                     "INCLINATION", "RA_OF_ASC_NODE", "ARG_OF_PERICENTER", "MEAN_ANOMALY",
                                     "BSTAR", "MEAN_MOTION_DOT", "MEAN_MOTION_DDOT")}
        cases.append(build_case(name.lower().replace(" ", "-"), omm, None, DEFAULT_MINUTES)[0])

    json.dump({"generator": "python-sgp4 2.25, WGS-72, opsmode a", "cases": cases}, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
