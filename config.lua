Config = {}

Config.Debug = false   -- prints scan/read lines. Set false before shipping.

Config.ResourceName   = 'distortionz_flock'
Config.CurrentVersion = '1.1.0'

-- ─── Version checker ────────────────────────────────────────────────
Config.VersionCheck = {
    -- Enable once the repo exists on GitHub.
    enabled      = false,
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

-- ─── Anti-spam ──────────────────────────────────────────────────────
-- Server-authoritative. The same plate at the same camera is only
-- recorded once per this many seconds — stops a car parked in range
-- writing one row per second forever.
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
    -- Deliberately different from distortionz_speedcam's prop_cctv_cam_02a
    -- so players can tell a plate reader from a speed trap at a glance.
    model      = 'prop_cctv_cam_04a',

    -- Pole beneath the camera. Set to false for cameras mounted on
    -- existing world geometry (gantries, overpasses) where a pole clips.
    pole       = 'prop_cctv_pole_02',
    poleOffset = 2.2,   -- metres below the camera Z

    -- Configured Z is used verbatim, never ground-snapped.
    invincible = true,
    freeze     = true,
}

-- ─── Feed camera controls ───────────────────────────────────────────
-- Arrow keys pan/tilt while a feed is open. Pan is a full unclamped 360°
-- (a fixed camera can still swivel on its mount); tilt is clamped so it
-- can't flip past straight up/down.
Config.FeedControl = {
    panSpeed  = 70.0,   -- degrees/second, left/right
    tiltSpeed = 55.0,   -- degrees/second, up/down
    minPitch  = -75.0,
    maxPitch  = 45.0,

    -- Mouse wheel zoom. Lower FOV = more zoomed in.
    defaultFov = 50.0,
    zoomStep   = 4.0,   -- FOV degrees per scroll tick
    minFov     = 15.0,  -- most zoomed in
    maxFov     = 65.0,  -- most zoomed out
}

-- ─── Feed traffic ───────────────────────────────────────────────────
-- GTA's ambient population only spawns around the real player ped, not a
-- focus point — so an officer's ped stays exactly where they physically
-- are (visible, untouched) and this scripts in a handful of vehicles near
-- the camera instead. Local-only: never networked, never seen by anyone
-- but the viewing officer, despawned the moment the feed closes.
Config.FeedTraffic = {
    enabled      = true,
    vehicleCount = 4,
    searchRadius = 35.0,   -- how far from the camera to look for road nodes

    models = {
        'asea', 'ingot', 'premier', 'stanier', 'tailgater',
        'washington', 'blista', 'primo', 'oracle', 'emperor',
    },
    driverModels = {
        'a_m_y_business_01', 'a_m_m_business_01',
        'a_f_y_business_02', 'a_m_y_soucent_01',
    },

    driveSpeed   = 12.0,     -- m/s, roughly city street pace
    drivingStyle = 786603,   -- normal: obeys traffic, avoids cars
}

-- ─── Cameras ────────────────────────────────────────────────────────
-- coords  : vec4(x, y, z, heading) — z/heading are the PROP placement.
-- id      : stable key, used for cooldowns and the reads table.
-- label   : human name shown to officers in search results and alerts.
-- model   : (optional) per-camera prop override.
-- pole    : (optional) per-camera pole override, or false for none.
-- enabled : (optional) set false to disable a single camera.
--
-- NOTE: these are seeded placements and the Z values are approximate.
-- Stand where you want each one and use distortionz_coords to capture an
-- exact vec4, then paste it in. Verify before shipping.
Config.Cameras = {
    { id = 'elysian_fwy',      label = 'Elysian Fields Fwy',   coords = vec4(  424.0, -1830.0,  29.0, 140.0) },
    { id = 'olympic_fwy_e',    label = 'Olympic Fwy East',     coords = vec4( -430.0, -1200.0,  30.0, 320.0) },
    { id = 'la_puerta_under',  label = 'La Puerta Underpass',  coords = vec4(-1180.0, -1560.0,   5.0, 210.0) },
    { id = 'del_perro_fwy_n',  label = 'Del Perro Fwy North',  coords = vec4(-1480.0,  -540.0,  32.0, 300.0) },
    { id = 'vinewood_hills',   label = 'Vinewood Hills Rd',    coords = vec4(  680.0,   580.0, 129.0, 190.0) },
    { id = 'senora_fwy_s',     label = 'Senora Fwy South',     coords = vec4( 2380.0,  2540.0,  47.0,  60.0) },
    { id = 'route68_harmony',  label = 'Route 68 — Harmony',   coords = vec4( 1180.0,  2660.0,  38.0,  90.0) },
    { id = 'great_ocean_chum', label = 'Great Ocean Hwy',      coords = vec4(-3080.0,  1140.0,  20.0, 240.0) },
    { id = 'paleto_blvd',      label = 'Paleto Blvd',          coords = vec4( -320.0,  6240.0,  31.0,  45.0) },
    { id = 'grapeseed_main',   label = 'Grapeseed Main St',    coords = vec4( 1700.0,  4780.0,  42.0,  15.0) },
    { id = 'zancudo_rd',       label = 'Zancudo Rd',           coords = vec4(-2100.0,  3200.0,  32.0, 150.0) },
    { id = 'legion_sq',        label = 'Legion Square',        coords = vec4(  200.0,  -940.0,  30.0, 160.0) },
    { id = 'mirror_park',      label = 'Mirror Park Blvd',     coords = vec4( 1120.0,  -640.0,  56.0, 270.0) },
    { id = 'strawberry_ave',   label = 'Strawberry Ave',       coords = vec4(  180.0, -1680.0,  29.0, 230.0) },
    { id = 'port_of_ls',       label = 'Port of LS',           coords = vec4(  830.0, -2960.0,   5.0,  90.0) },
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
