# Distortionz Flock

> Server-authoritative ALPR + speed camera network. Fixed cameras passively read plates and/or clock speed, log every sighting, auto-alert police on hotlisted plates, active BOLOs, and speeding — with an audit trail and real counterplay.

![FiveM](https://img.shields.io/badge/FiveM-cerulean-yellow?style=flat-square&labelColor=181b20)
![Qbox](https://img.shields.io/badge/Qbox-optional-blue?style=flat-square&labelColor=181b20)
![License](https://img.shields.io/badge/License-MIT-brightgreen?style=flat-square)

---

## Overview

One camera network, two jobs: **ALPR** (reads plates, checks them against a hotlist and against `distortionz_cad`'s BOLO board) and **speed enforcement** (clocks vehicles, fines the driver, alerts police). Each camera in `Config.Cameras` declares which job(s) it does via `modes` — plate reader, speed trap, or both on one pole.

A plate hit — hotlisted or BOLO'd — triggers an alert regardless of who's driving or who the vehicle is registered to; the match is on the plate string alone. Officers can also search a plate's history, manage the hotlist, and see which cameras are online.

## Why detection is server-side

Every check here — plate, position, speed — is computed by the server itself, off its own vehicle handles. The client never sends a plate, a speed, a position, or a camera id for a read; the only thing a client *can* send is a camera id to tamper with, and that's distance-checked against the server's own coords before it's honoured.

Speed detection specifically didn't start this way: this resource absorbed `distortionz_speedcam`, which read the vehicle's speed and **plate** client-side and sent both to the server, trusting them as-is. That's exactly the kind of client-trust gap that shouldn't survive a rewrite — a cheater could submit someone else's plate. Speed detection now runs on the same server-side scan pass as ALPR, computing speed via `GetEntitySpeed` on the server's own handle and reading the plate the same way ALPR does. Nothing about a speed violation is client-supplied anymore.

## Features

- Fully server-side plate **and** speed detection — no client trust anywhere in either path
- Grid-bucketed camera lookup, so cost stays flat as the camera list grows
- Batched multi-row inserts for reads; instant single-row inserts for citations (much lower volume)
- Per-plate/per-camera cooldowns (separate for reads vs. speed citations) so a parked car can't flood either table
- Hotlist with auto-alert to police + `distortionz_cad` dispatch call
- **Automatic BOLO ping** — every plate read is also checked against `distortionz_cad`'s active Vehicle BOLOs; a hit alerts police the same way a hotlist hit does, independent of the hotlist
- **Speed enforcement** — escalating fine (`base + perUnitOver × over`, clamped), billed from the offender's bank first and cash as fallback, with a chance-based police dispatch alert on top of the citation itself
- Plate history search, rate-limited per officer
- Full audit log of every search and hotlist change
- Counterplay — cameras can be tampered offline (both jobs go down together), with a chance of alerting police
- Automatic pruning of old reads (citations are kept — they're financial records, not sighting history)

## Dependencies

| Resource | Required | Purpose |
|---|---|---|
| `ox_lib` | yes | Callbacks, context menus, dialogs, progress bar |
| `oxmysql` | yes | Persistence |
| `qbx_core` | optional | Job-based access + billing; falls back to ACE/log-only when absent |
| `distortionz_notify` | optional | Notifications; falls back to `lib.notify` |
| `distortionz_cad` | optional | Dispatch calls on hotlist/BOLO/speed hits, and the source of truth for BOLO matches |
| `ox_inventory` | optional | Only if `Config.Counterplay.item` is set |
| `ox_target` | optional | Tamper cameras by targeting the prop directly; falls back to `/flocktamper` when absent |

## Installation

1. Import `sql/distortionz_flock.sql`.
2. Add to `server.cfg`:

```cfg
ensure ox_lib
ensure oxmysql
ensure distortionz_notify
ensure distortionz_cad
ensure distortionz_flock
```

3. Standalone servers (no `qbx_core`) grant officer access via ACE:

```cfg
add_ace group.admin flock.police allow
```

BOLO pinging needs no extra wiring beyond `distortionz_cad` being installed — flock calls its `CheckVehicleBolo` export automatically on every read.

## Commands

```
/flock          -- officer menu: search, hits, hotlist, cameras
/flocktamper    -- disable the nearest camera (counterplay, both modes)
```

## Camera placement

`Config.Cameras` entries need `modes` (`{'alpr'}`, `{'speed'}`, or both) and, for speed-mode cameras, a `limit`. **None of the shipped coordinates are field-verified.** Stand where you want each camera, capture an exact `vec4` with `distortionz_coords`, and paste it in before shipping.

Cameras are pole-mounted: the configured Z is used verbatim and never ground-snapped. Set `pole = false` on a camera mounted to existing world geometry so the pole doesn't clip through it. Per-camera `model`/`blip` overrides are available for cameras that should look or show differently from the resource-wide default (see the comment block above `Config.Cameras`).

## Speed enforcement

See `Config.SpeedDetection` (unit, radii, tolerance, driver-only, cooldown), `Config.SpeedAlert` (chance-based police ping — a speeding pass is a much more everyday event than a hotlist/BOLO hit, so it doesn't always page dispatch the way those do), and `Config.Fine` (the fine formula and billing accounts). Every citation is logged to `distortionz_flock_speed_violations` regardless of whether it could be billed (e.g. no `qbx_core` running).

## Access control

On Qbox, an officer must hold a job in `Config.Access.jobs` and be on duty if `requireOnDuty` is set. Without a framework it falls back to the `flock.police` ACE.

Searches are rate-limited to `Config.Access.searchesPerMinute` per officer. Every search and hotlist change is written to `distortionz_flock_audit` — real ALPR systems are audited precisely because the abuse risk is an officer quietly tracking someone, and the same is true in RP.

## Balance note

`Config.Counterplay` is enabled by default. Turning it off makes the camera network undefeatable, which removes any decision from the criminal side. If you disable it, consider reducing camera coverage to compensate.

## Credits

- **Author:** Distortionz
- **Companion resources:** `distortionz_cad`, `distortionz_notify`

## License

MIT — see [LICENSE](LICENSE).
