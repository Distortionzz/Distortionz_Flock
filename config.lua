Config = {}

Config.Debug = false       -- prints scan/read lines. Set false before shipping.

Config.ResourceName   = 'distortionz_flock'
Config.CurrentVersion = '2.1.0'

-- ─── Version checker ────────────────────────────────────────────────
Config.VersionCheck = {
    enabled      = true,
    url          = 'https://raw.githubusercontent.com/Distortionzz/Distortionz_Flock/main/version.json',
    checkOnStart = true,
}

-- ─── Notify integration ─────────────────────────────────────────────
Config.Notify = {
    title                = 'Flock',
    useDistortionzNotify = true,
}

-- ─── Detection ──────────────────────────────────────────────────────
-- Detection is FULLY SERVER-SIDE. The server iterates networked vehicles
-- and reads plates itself, so a client never reports a plate and plate
-- spoofing is impossible by construction.
Config.Detection = {
    -- How often the server sweeps for vehicles near cameras (ms).
    -- 1000ms catches anything under ~140 mph given the capture radius.
    intervalMs      = 1000,

    -- Horizontal capture radius (metres) around a camera.
    captureRadius   = 22.0,

    -- Max vertical gap (metres) between vehicle and camera Z. Stops a
    -- street-level camera reading a car on the overpass above it.
    verticalBand    = 9.0,

    -- Only read vehicles with someone inside. World/ambient traffic is
    -- not networked to the server anyway, but this also skips abandoned
    -- cars parked in range from filling the reads table.
    requireOccupant = true,

    -- Grid cell size (metres) for camera bucketing. Each vehicle only
    -- tests cameras in its own cell, so cost stays flat as cameras grow.
    -- Must be >= 2 * captureRadius.
    cellSize        = 150.0,
}

-- ─── Speed detection ────────────────────────────────────────────────
-- Also fully server-side: the server computes speed off its own vehicle
-- handle (GetEntitySpeed) and reads the plate itself, on the same scan
-- pass as ALPR above — a client never reports a speed or a plate for
-- this either. Rides Config.Detection.intervalMs, not a separate timer.
Config.SpeedDetection = {
    -- 'mph' or 'kmh' — applies to camera limits, fines, and notify text.
    unit            = 'mph',

    -- A vehicle is captured when the path it travelled *this tick* passes
    -- within this many metres (horizontal) of a camera while over the
    -- limit. Segment-tested, not point-tested, so a fast pass can't
    -- tunnel between two 1-second samples.
    captureRadius   = 16.0,

    -- Max vertical gap (metres) between vehicle and camera Z.
    verticalBand    = 8.0,

    -- Grace buffer added on top of the camera limit before a fine fires
    -- (in the configured unit). Stops borderline/needle-jitter flashes.
    tolerance       = 4,

    -- Only the driver is fined.
    driverOnly      = true,

    -- Separate from Config.CooldownSeconds below (that one's for ALPR
    -- reads/hotlist/BOLO). Same plate + same camera can only be fined
    -- once per this many seconds.
    cooldownSeconds = 5,
}

-- ─── Anti-spam ──────────────────────────────────────────────────────
-- Server-authoritative. The same plate at the same camera is only
-- recorded once per this many seconds — stops a car parked in range
-- writing one row per second forever. ALPR/hotlist/BOLO only — speed
-- fines use Config.SpeedDetection.cooldownSeconds instead.
Config.CooldownSeconds = 30

-- ─── Database ───────────────────────────────────────────────────────
Config.Database = {
    -- Reads are queued and flushed as a single multi-row INSERT rather
    -- than one query per read. Keeps DB load flat during rush hour.
    flushIntervalMs = 5000,

    -- Reads older than this are pruned on start and every 6h.
    -- Set to 0 to keep history forever.
    retentionDays   = 14,
}

-- ─── Access control ─────────────────────────────────────────────────
-- On Qbox: job name must be in `jobs`, and on duty if `requireOnDuty`.
-- Standalone (no qbx_core): falls back to the `flock.police` ACE.
--   add_ace group.admin flock.police allow
Config.Access = {
    jobs          = { 'police', 'sheriff', 'fib' },
    requireOnDuty = true,
    acePermission = 'flock.police',

    -- Max plate searches per officer per minute. Cheap table lookup;
    -- stops a compromised account scraping the whole read history.
    searchesPerMinute = 10,
}

-- ─── Hotlist alerts ─────────────────────────────────────────────────
Config.Alert = {
    enabled       = true,
    code          = '10-99',
    label         = 'Flock hit',
    delayMs       = { min = 800, max = 2000 },
    blipTimeoutMs = 60000,

    -- Also open a dispatch call in distortionz_cad when it is running.
    useCad        = true,
    cadPriority   = 1,
}

-- ─── BOLO alerts ────────────────────────────────────────────────────
-- Independent of the hotlist above. Every ALPR read is also checked
-- against distortionz_cad's own BOLO board (type='Vehicle', status=
-- 'active' only) — if an officer has put a plate on a BOLO, seeing it
-- again anywhere fires this, regardless of who's driving or who it's
-- registered to. Same delivery path as a hotlist hit (FireHit), just a
-- different trigger and wording.
Config.Bolo = {
    enabled       = true,
    code          = 'BOLO',
    label         = 'BOLO hit — vehicle',
    blipTimeoutMs = 60000,
    useCad        = true,
    cadPriority   = 1,
}

-- ─── Speed camera dispatch alert ────────────────────────────────────
-- Separate from Config.Alert/Config.Bolo above: a speeding pass is a much
-- more everyday event than a hotlist/BOLO hit, so it's chance-based
-- rather than always firing. Who counts as "police" for delivery is
-- GetOfficers() — the same definition used everywhere else in this
-- resource, not a separate job list.
Config.SpeedAlert = {
    enabled       = true,
    chance        = 1.0,   -- per-violation chance to also ping police (1.0 = every time)
    delayMs       = { min = 1500, max = 4000 },
    code          = '10-55',
    label         = 'Speed camera triggered',
    blipTimeoutMs = 45000,
    useCad        = true,
    cadPriority   = 3,
}

-- ─── Speed camera fine ──────────────────────────────────────────────
-- fine = clamp( base + perUnitOver * (speed - limit), min, max ), rounded.
-- Pulled from the offender's qbx bank first, then cash if bank is short.
-- No qbx_core running (standalone mode): the violation is still logged,
-- just not billed.
Config.Fine = {
    account     = 'bank',
    fallback    = 'cash',
    base        = 250,
    perUnitOver = 30,
    min         = 250,
    max         = 6000,
    reason      = 'speed-camera-fine',
}

-- ─── Counterplay ────────────────────────────────────────────────────
-- Without this, PD is unbeatable and the cameras stop being interesting.
-- A player near a camera can disable it for a while. The server validates
-- distance and item ownership; the client only ever sends the camera id.
Config.Counterplay = {
    enabled       = true,

    -- Required ox_inventory item. Set to false for no item requirement.
    item          = false,

    -- Consume the item on a successful disable.
    consumeItem   = true,

    -- Player must be within this many metres of the camera.
    useRadius     = 3.0,

    -- Progress bar duration (ms) before the camera goes down.
    duration      = 8000,

    -- How long the camera stays offline (seconds).
    downtime      = 600,

    -- Chance (0.0-1.0) that tampering pings police anyway.
    alertChance   = 0.5,
    alertCode     = '10-66',
    alertLabel    = 'Camera tampering',
}

-- ─── Camera prop ────────────────────────────────────────────────────
Config.Prop = {
    -- Every camera is the same dual-purpose (ALPR + speed) unit, so one
    -- default model for the whole network. Override per-camera via
    -- Config.Cameras[i].model if you want a specific pole to look
    -- different — purely cosmetic, doesn't affect what it detects.
    model      = 'prop_cctv_unit_01',

    -- Pole beneath the camera. Set to false for cameras mounted on
    -- existing world geometry (gantries, overpasses) where a pole clips.
    pole       = 'prop_cctv_pole_02',
    poleOffset = 2.2,   -- metres below the camera Z

    -- Configured Z is used verbatim, never ground-snapped.
    invincible = true,
    freeze     = true,
}

-- ─── Cameras ────────────────────────────────────────────────────────
-- coords  : vec4(x, y, z, heading) — z/heading are the PROP placement.
-- id      : stable key, used for cooldowns and the reads/violations tables.
-- label   : human name shown to officers in search results and alerts.
-- modes   : REQUIRED. { 'alpr' }, { 'speed' }, or { 'alpr', 'speed' } —
--           one camera, one job, both, or a combo pole.
-- limit   : speed limit in Config.SpeedDetection.unit. Required if 'speed'
--           is in modes, ignored otherwise.
-- model   : (optional) per-camera prop override.
-- pole    : (optional) per-camera pole override, or false for none.
-- enabled : (optional) set false to disable a single camera (both modes).
-- blip    : (optional) { sprite=, color=, scale=, label= } per-camera
--           override of Config.Blip.
--
-- NOTE: none of these are field-verified. Stand where you want each one
-- and use distortionz_coords to capture an exact vec4, then paste it in.
-- Verify before shipping.
--
-- Every camera is dual-mode (alpr + speed) — one uniform network, every
-- pole does both jobs.
Config.Cameras = {
    { id = 'olympic_fwy_e', label = 'Olympic Fwy East',   coords = vec4(-429.20, -1196.40, 19.63, 262.3),
      modes = { 'alpr', 'speed' }, limit = 65 },
    -- Field-captured, not a placeholder. Heading nudged 90° from capture
    -- so the two lenses split across both directions of travel instead
    -- of both favoring one lane — adjust further if it's not quite right.
    { id = 'la_puerta_hwy', label = 'La Puerta Highway',  coords = vec4(-631.05, -1721.93, 36.85, 196.97),
      modes = { 'alpr', 'speed' }, limit = 65 },
}

-- ─── Blips ──────────────────────────────────────────────────────────
-- policeOnly keeps them off civilian maps — real plate readers aren't
-- signposted, and hiding them from criminals is what makes the
-- counterplay a decision rather than a checklist.
Config.Blip = {
    enabled    = true,
    sprite     = 184,
    color      = 3,
    scale      = 0.7,
    label      = 'Flock Camera',
    shortRange = true,

    -- Show blips only to players who pass Config.Access (police).
    policeOnly = true,
}
