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
    "2 25544  51.6311 178.9253 0004254  36.7694 323.3591 15.50035835533354",
)
DEFAULT_MINUTES = [-1440.0, -360.0, 0.0, 360.0, 1440.0, 4320.0]
XPDOTP = 1440.0 / (2.0 * math.pi)

# Observer-frame samples for the Swift topocentric tests: where the owner's antenna is, every 10 minutes for a day.
LOOK_OBSERVER = (35.2534, -109.4374, 1800.0)  # latitude, longitude (degrees), altitude (metres)
LOOK_CASES = ("iss-2025-09-30", "meteor-m2-4")
LOOK_MINUTES = [i * 10.0 for i in range(0, 145)]
WGS84_A = 6378.137
WGS84_F = 1 / 298.257223563
EARTH_ROTATION = 7.292115146706979e-5  # rad/s
J2000 = dt.datetime(2000, 1, 1, 12, 0, 0)

# Expected passes: a 1-second brute-force search with the geodesy above (independent of the Swift code).
PASS_CASES = ("iss-2025-09-30", "meteor-m2-4", "noaa-21-(jpss-2)")
PASS_OBSERVERS = [(35.2534, -109.4374, 1800.0), (-33.8688, 151.2093, 50.0)]
PASS_DAYS = 3
PASS_MIN_ELEVATIONS = (5.0, 10.0)
DECAY_CASE = "ver-28872"  # decays 55 minutes after its epoch; the observer sits under its track at minute 20


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


def gmst_radians(moment):
    """IAU-1982 GMST for a UTC datetime, treating UTC as UT1 (the same simplification the Swift code documents)."""
    days = (moment - J2000).total_seconds() / 86400.0
    t = days / 36525.0
    deg = 280.46061837 + 360.98564736629 * days + 0.000387933 * t * t - t * t * t / 38710000.0
    return math.radians(deg % 360.0)


def observer_ecef(lat_deg, lon_deg, alt_m):
    lat, lon, h = math.radians(lat_deg), math.radians(lon_deg), alt_m / 1000.0
    e2 = WGS84_F * (2 - WGS84_F)
    n = WGS84_A / math.sqrt(1 - e2 * math.sin(lat) ** 2)
    return [(n + h) * math.cos(lat) * math.cos(lon), (n + h) * math.cos(lat) * math.sin(lon),
            (n * (1 - e2) + h) * math.sin(lat)]


def look_samples(sat, epoch, observer, minutes_list):
    """Azimuth, elevation, range and range-rate by rotation matrices (south-east-zenith), independent of the Swift code."""
    lat, lon = math.radians(observer[0]), math.radians(observer[1])
    obs = observer_ecef(*observer)
    out = []
    for minutes in minutes_list:
        e, r, v = sat.sgp4_tsince(minutes)
        if e != 0:
            continue
        gmst = gmst_radians(epoch + dt.timedelta(minutes=minutes))
        c, s_ = math.cos(gmst), math.sin(gmst)
        r_e = [c * r[0] + s_ * r[1], -s_ * r[0] + c * r[1], r[2]]
        # Velocity relative to the rotating Earth: rotate, then subtract omega x r.
        v_e = [c * v[0] + s_ * v[1] + EARTH_ROTATION * r_e[1], -s_ * v[0] + c * v[1] - EARTH_ROTATION * r_e[0], v[2]]
        rho = [r_e[i] - obs[i] for i in range(3)]
        south = math.sin(lat) * math.cos(lon) * rho[0] + math.sin(lat) * math.sin(lon) * rho[1] - math.cos(lat) * rho[2]
        east = -math.sin(lon) * rho[0] + math.cos(lon) * rho[1]
        zenith = math.cos(lat) * math.cos(lon) * rho[0] + math.cos(lat) * math.sin(lon) * rho[1] + math.sin(lat) * rho[2]
        rng = math.sqrt(sum(x * x for x in rho))
        out.append({
            "minutes": minutes,
            "az": math.degrees(math.atan2(east, -south)) % 360.0,
            "el": math.degrees(math.asin(zenith / rng)),
            "rangeKM": rng,
            "rangeRateKMS": sum(rho[i] * v_e[i] for i in range(3)) / rng,
        })
    return {"observer": list(observer), "samples": out}


class _Site:
    """Observer constants for the fast elevation-only loop."""

    def __init__(self, observer):
        self.lat, self.lon = math.radians(observer[0]), math.radians(observer[1])
        self.ecef = observer_ecef(*observer)
        self.sl, self.cl = math.sin(self.lat), math.cos(self.lat)
        self.so, self.co = math.sin(self.lon), math.cos(self.lon)


def _elevation_at(sat, site, epoch_days, minutes):
    """Elevation in degrees, or None where SGP4 reports an error."""
    e, r, _ = sat.sgp4_tsince(minutes)
    if e != 0:
        return None
    days = epoch_days + minutes / 1440.0
    t = days / 36525.0
    gmst = math.radians((280.46061837 + 360.98564736629 * days + 0.000387933 * t * t - t * t * t / 38710000.0) % 360.0)
    c, s_ = math.cos(gmst), math.sin(gmst)
    rx, ry, rz = c * r[0] + s_ * r[1] - site.ecef[0], -s_ * r[0] + c * r[1] - site.ecef[1], r[2] - site.ecef[2]
    zenith = site.cl * site.co * rx + site.cl * site.so * ry + site.sl * rz
    return math.degrees(math.asin(zenith / math.sqrt(rx * rx + ry * ry + rz * rz)))


def brute_force_passes(sat, epoch, observer, start_minutes, end_minutes, min_elevation, step_seconds=1.0):
    """Passes above `min_elevation` between two times (minutes after the element epoch), found by sampling every
    second, with linear interpolation for the crossings and a parabola through the peak. Stops at an SGP4 failure
    and returns its minute; a pass still up at that moment is dropped (its end is unknown)."""
    site = _Site(observer)
    epoch_days = (epoch - J2000).total_seconds() / 86400.0
    step = step_seconds / 60.0
    count = int(round((end_minutes - start_minutes) / step))
    values, failure = [], None
    for k in range(count + 1):
        minutes = start_minutes + k * step
        el = _elevation_at(sat, site, epoch_days, minutes)
        if el is None:
            failure = minutes
            break
        values.append(el)
    passes, k = [], 0
    n = len(values)
    while k < n:
        if values[k] < min_elevation:
            k += 1
            continue
        first = k
        while k < n and values[k] >= min_elevation:
            k += 1
        last = k - 1
        starts_before = first == 0
        ends_after = last == n - 1 and failure is None
        if last == n - 1 and failure is not None:
            break  # still up when SGP4 failed: the end is unknown
        def crossing(a, b):
            frac = (min_elevation - values[a]) / (values[b] - values[a])
            return start_minutes + (a + frac) * step
        aos = start_minutes if starts_before else crossing(first - 1, first)
        los = end_minutes if ends_after else crossing(last, last + 1)
        peak = max(range(first, last + 1), key=lambda i: values[i])
        tca, max_el = start_minutes + peak * step, values[peak]
        if 0 < peak < n - 1:
            a, b, c = values[peak - 1], values[peak], values[peak + 1]
            denom = a - 2 * b + c
            if denom != 0:
                d = 0.5 * (a - c) / denom
                tca, max_el = start_minutes + (peak + d) * step, b - 0.25 * (a - c) * d
        passes.append({"aosMinutes": aos, "tcaMinutes": tca, "losMinutes": los, "maxEl": max_el,
                       "startsBeforeWindow": starts_before, "endsAfterWindow": ends_after})
    return passes, failure


def iso(epoch, minutes):
    return (epoch + dt.timedelta(minutes=minutes)).isoformat(timespec="microseconds")


def pass_entries(sat, omm, observers, days, min_elevations):
    epoch = dt.datetime.fromisoformat(omm["EPOCH"])
    entries = []
    for observer in observers:
        for min_el in min_elevations:
            found, failure = brute_force_passes(sat, epoch, observer, 0.0, days * 1440.0, min_el)
            entries.append({
                "observer": list(observer), "from": iso(epoch, 0.0), "through": iso(epoch, days * 1440.0),
                "minElevation": min_el, "failureMinutes": failure,
                "list": [{"aos": iso(epoch, p["aosMinutes"]), "tca": iso(epoch, p["tcaMinutes"]),
                          "los": iso(epoch, p["losMinutes"]), "maxEl": p["maxEl"],
                          "startsBeforeWindow": p["startsBeforeWindow"], "endsAfterWindow": p["endsAfterWindow"]}
                         for p in found]})
    return entries


def subpoint_observer(sat, epoch, minutes, altitude_m=0.0):
    """An observer directly under the satellite at a given minute (geocentric latitude is close enough to put it overhead)."""
    _, r, _ = sat.sgp4_tsince(minutes)
    gmst = gmst_radians(epoch + dt.timedelta(minutes=minutes))
    c, s_ = math.cos(gmst), math.sin(gmst)
    x, y, z = c * r[0] + s_ * r[1], -s_ * r[0] + c * r[1], r[2]
    return (math.degrees(math.atan2(z, math.hypot(x, y))), math.degrees(math.atan2(y, x)), altitude_m)


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
    for case in cases:
        if case["name"] == DECAY_CASE:
            omm = case["omm"]
            sat = satrec_from_omm(omm)
            observer = subpoint_observer(sat, dt.datetime.fromisoformat(omm["EPOCH"]), 20.0)
            case["passes"] = pass_entries(sat, omm, [observer], 1, (5.0,))

    def add_case(name, omm, tle):
        case, sat, _ = build_case(name, omm, tle, DEFAULT_MINUTES)
        if name in LOOK_CASES:
            case["look"] = look_samples(sat, dt.datetime.fromisoformat(omm["EPOCH"]), LOOK_OBSERVER, LOOK_MINUTES)
        if name in PASS_CASES:
            case["passes"] = pass_entries(sat, omm, PASS_OBSERVERS, PASS_DAYS, PASS_MIN_ELEVATIONS)
        cases.append(case)

    add_case("iss-2025-09-30", omm_from_tle("ISS (ZARYA)", *ISS), ISS)

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
        add_case(name.lower().replace(" ", "-"), omm, None)

    json.dump({"generator": "python-sgp4 2.25, WGS-72, opsmode a; passes by 1 s brute force with an independent geodesy, "
                 "cross-checked with skyfield 1.55 by script/verify_passes_skyfield.py", "cases": cases}, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
