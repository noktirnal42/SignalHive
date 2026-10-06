#!/usr/bin/env python3
"""Cross-check the pass oracle against skyfield, a third-party predictor with its own frames and time scales.

The oracle's expected passes come from a 1-second brute-force search with simple geodesy (UTC taken as UT1, no polar
motion). skyfield uses the real UT1 and polar motion, so the two should agree to well under a second; if they do not,
the oracle (and the Swift predictor measured against it) is suspect. Run it in a throwaway venv:

    python3 -m venv /tmp/skyvenv && /tmp/skyvenv/bin/pip install skyfield
    /tmp/skyvenv/bin/python script/verify_passes_skyfield.py Packages/SignalHiveCore/Tests/Core/Fixtures/sgp4-oracle.json
"""
import datetime as dt
import json
import sys

from skyfield.api import EarthSatellite, load, wgs84

TOLERANCE_SECONDS = 3.0
TOLERANCE_DEGREES = 0.1


def parse(text):
    return dt.datetime.fromisoformat(text).replace(tzinfo=dt.timezone.utc)


def main(path):
    oracle = json.load(open(path))
    ts = load.timescale()
    worst = {"aos": 0.0, "tca": 0.0, "los": 0.0, "maxEl": 0.0}
    compared = 0
    for case in oracle["cases"]:
        entries = [e for e in case.get("passes", []) if e["failureMinutes"] is None]
        if not entries:
            continue
        fields = dict(case["omm"])
        fields.setdefault("OBJECT_ID", "0000-000A")
        fields.setdefault("EPHEMERIS_TYPE", 0)
        fields.setdefault("CLASSIFICATION_TYPE", "U")
        fields.setdefault("ELEMENT_SET_NO", 999)
        fields.setdefault("REV_AT_EPOCH", 0)
        satellite = EarthSatellite.from_omm(ts, fields)
        for entry in entries:
            lat, lon, altitude = entry["observer"]
            site = wgs84.latlon(lat, lon, elevation_m=altitude)
            t0, t1 = ts.from_datetime(parse(entry["from"])), ts.from_datetime(parse(entry["through"]))
            times, events = satellite.find_events(site, t0, t1, altitude_degrees=entry["minElevation"])
            triples = []
            for index in range(len(events) - 2):
                if list(events[index:index + 3]) == [0, 1, 2]:
                    triples.append(times[index:index + 3])
            for expected in (p for p in entry["list"] if not p["startsBeforeWindow"] and not p["endsAfterWindow"]):
                aos = parse(expected["aos"])
                match = min(triples, key=lambda t: abs((t[0].utc_datetime() - aos).total_seconds()), default=None)
                if match is None:
                    sys.exit(f"{case['name']}: skyfield found no pass near {expected['aos']}")
                rise, culminate, set_ = (t.utc_datetime() for t in match)
                peak = (satellite - site).at(match[1]).altaz()[0].degrees
                deltas = {
                    "aos": abs((rise - aos).total_seconds()),
                    "tca": abs((culminate - parse(expected["tca"])).total_seconds()),
                    "los": abs((set_ - parse(expected["los"])).total_seconds()),
                    "maxEl": abs(peak - expected["maxEl"]),
                }
                for key, value in deltas.items():
                    worst[key] = max(worst[key], value)
                compared += 1
            skyfield_complete = len(triples)
            oracle_complete = sum(1 for p in entry["list"] if not p["startsBeforeWindow"] and not p["endsAfterWindow"])
            if skyfield_complete != oracle_complete:
                sys.exit(f"{case['name']} {entry['observer']} min {entry['minElevation']}: "
                         f"skyfield {skyfield_complete} complete passes, oracle {oracle_complete}")
    print(f"compared {compared} passes against skyfield: worst AOS {worst['aos']:.3f} s, TCA {worst['tca']:.3f} s, "
          f"LOS {worst['los']:.3f} s, max elevation {worst['maxEl']:.4f} deg")
    if max(worst["aos"], worst["tca"], worst["los"]) > TOLERANCE_SECONDS or worst["maxEl"] > TOLERANCE_DEGREES:
        sys.exit("the oracle and skyfield disagree beyond tolerance")


if __name__ == "__main__":
    main(sys.argv[1])
