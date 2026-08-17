# Distortionz Flock

> Server-authoritative ALPR camera network. Fixed cameras passively read plates, log every sighting, auto-alert police on hotlisted plates, and give officers a searchable sighting history — with an audit trail and real counterplay.

![FiveM](https://img.shields.io/badge/FiveM-cerulean-yellow?style=flat-square&labelColor=181b20)
![Qbox](https://img.shields.io/badge/Qbox-optional-blue?style=flat-square&labelColor=181b20)
![License](https://img.shields.io/badge/License-MIT-brightgreen?style=flat-square)

---

## Overview

Cameras read the plate of any vehicle that passes within range. Sightings are written to the database; if the plate is on the hotlist, police get an alert and a dispatch call. Officers can search a plate's history, manage the hotlist, and see which cameras are online.

## Why detection is server-side

`distortionz_speedcam` uses client-detects → server-validates. That is fine for speed, but the **plate** it sends is client-supplied, so a cheater can submit someone else's plate.

Flock avoids that class of bug entirely: the server iterates vehicles, calls `GetVehicleNumberPlateText` itself, and does the distance maths against its own config. The client never sends a plate, a position, or a camera id for a read — so there is nothing to forge.

The one thing a client *can* send is a camera id to tamper with, and that is distance-checked against the server's own coords before it is honoured.

## Features

- Fully server-side plate detection — no client trust anywhere in the read path
- Grid-bucketed camera lookup, so cost stays flat as the camera list grows
- Batched multi-row inserts instead of one query per read
- Per-plate/per-camera cooldown so a parked car can't flood the table
- Hotlist with auto-alert to police + `distortionz_cad` dispatch call
- Plate history search, rate-limited per officer
- Full audit log of every search and hotlist change
- Counterplay — cameras can be tampered offline, with a chance of alerting police
- Automatic pruning of old reads

## Dependencies

| Resource | Required | Purpose |
|---|---|---|
| `ox_lib` | yes | Callbacks, context menus, dialogs, progress bar |
| `oxmysql` | yes | Persistence |
| `qbx_core` | optional | Job-based access; falls back to ACE when absent |
| `distortionz_notify` | optional | Notifications; falls back to `lib.notify` |
| `distortionz_cad` | optional | Dispatch calls on hotlist hits |
| `ox_inventory` | optional | Only if `Config.Counterplay.item` is set |

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

## Commands

```
/flock          -- officer menu: search, hits, hotlist, cameras
/flocktamper    -- disable the nearest camera (counterplay)
```

## Camera placement

`Config.Cameras` ships with 15 seeded placements, but **the Z values are approximate**. Stand where you want each camera, capture an exact `vec4` with `distortionz_coords`, and paste it in before shipping.

Cameras are pole-mounted: the configured Z is used verbatim and never ground-snapped. Set `pole = false` on a camera mounted to existing world geometry so the pole doesn't clip through it.

## Access control

On Qbox, an officer must hold a job in `Config.Access.jobs` and be on duty if `requireOnDuty` is set. Without a framework it falls back to the `flock.police` ACE.

Searches are rate-limited to `Config.Access.searchesPerMinute` per officer. Every search and hotlist change is written to `distortionz_flock_audit` — real ALPR systems are audited precisely because the abuse risk is an officer quietly tracking someone, and the same is true in RP.

## Balance note

`Config.Counterplay` is enabled by default. Turning it off makes the camera network undefeatable, which removes any decision from the criminal side. If you disable it, consider reducing camera coverage to compensate.

## Credits

- **Author:** Distortionz
- **Companion resources:** `distortionz_cad`, `distortionz_notify`, `distortionz_speedcam`

## License

MIT — see [LICENSE](LICENSE).
