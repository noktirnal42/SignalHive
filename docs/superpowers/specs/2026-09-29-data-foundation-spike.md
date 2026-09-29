# Data Foundation spike — measured results (2026-09-29)

Question from the spec (§9 step 2): what do real pack size, build time and memory look like?

## Setup
- Tool: `signalhive-packbuilder` (release build) on an Apple-silicon Mac, project on an external volume.
- Input: the real FCC `l_LMcomm.zip` (81,814,242 bytes; about 800 MB extracted; `EM.dat` alone is 358 MB), snapshot 2026-09-25.
- Not measured: `l_LMpriv.zip` (423 MB, the public-safety file). No local copy exists and downloading it needs the user's approval.

## Results (LMcomm only)
| Metric | Legacy importer (same archive) | New streaming builder |
|---|---|---|
| Wall time | ~171–197 s (test run) | **5.3 s** (5.7 s incl. process start) |
| Peak resident memory | not measured; whole tables held in memory | **47 MB** (peak footprint 27 MB) |
| Temp disk | ~800 MB extracted, never deleted | none (entries streamed from the zip; scratch DB removed) |
| Output | one 1 GB-class SQLite | 55 state packs, **3.4 MB compressed total** |

Sample packs (compressed / expanded): AL 0.13 / 0.58 MB (237 licenses, 4,553 frequencies), CA 0.31 / 1.13 MB, FL 0.26 / 1.12 MB.

## Correctness spot checks against the raw archive
- `WPCE842` (Jackson, Clarke Co., AL): pack lat/lon 31.53794 / −87.87306 equals the value recomputed by hand from the raw DMS fields at the corrected columns; raw status `A`.
- `KNNF642` (the earlier test row) is absent from the pack because the raw file marks it `C` (cancelled 2011): correct behaviour.
- Alabama pack: 65 counties (Jefferson 46, Mobile 20, Shelby 17 licenses ...); 13 of 473 sites lack a county and 14 lack coordinates.
- Mode hints across AL frequencies: mostly `digitalOther`, some `analogFM`, a few `ssb`; FTS5 search returns matches.

## What this does and does not tell us
- Streaming plus the active-only uid filter removes the two problems that made the legacy importer heavy (whole-table memory, unzip-to-disk). This is measured.
- Public-safety data (LMpriv) is roughly 5× the archive size of LMcomm. If build time and memory scale with archive size, that is on the order of tens of seconds and a modest memory footprint, but that is an extrapolation and must be measured once the user approves fetching that archive. Per-state pack sizes for LMpriv are unknown until then.
- Only 8,099 of the LMcomm licenses are active (`A`); the rest are cancelled or expired, which is why active-only filtering shrinks the data so much.

## Decision
The approach holds; continue with the plan. Re-measure with LMpriv when approved and adjust compression or scope only if the numbers warrant it.
