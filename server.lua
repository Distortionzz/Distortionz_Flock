-- =====================================================================
--  Distortionz Flock — server
--
--  Detection is entirely server-side: the server reads plates off the
--  vehicles itself. A client never submits a plate, a camera id for a
--  read, or a position, so there is nothing to spoof. The only thing a
--  client may send is a *camera id to tamper with*, and that is distance-
--  checked against the server's own coords before it is honoured.
-- =====================================================================

local cameraById   = {}   -- [id]   = cfg
local cameraGrid   = {}   -- ['cx:cy'] = { cfg, ... }
local disabledUntil= {}   -- [id]   = os.time() when the camera comes back
local lastRead     = {}   -- ['id|plate'] = os.time()
local lastFine     = {}   -- ['id|plate'] = os.time()
local hotlist      = {}   -- [plate] = { reason, added_by }
local readQueue    = {}   -- pending rows, flushed as one INSERT
local searchStamps = {}   -- [src]  = { os.time(), ... } rolling rate limit

-- Cross-tick vehicle position for the speed-camera anti-tunnel check.
-- [src] = { netId, x, y, z, t }. Rebuilt from scratch every scan tick
-- (see the main CreateThread below) rather than mutated in place — a
-- disconnected/parked/switched-vehicle entry just isn't written into the
-- fresh table, so it disappears on its own with no separate sweep.
local lastVehState = {}

local CELL, RADIUS

local function DebugPrint(message)
    if Config.Debug then
        print(('[%s:server] %s'):format(Config.ResourceName, message))
    end
end

-- ─── Camera index ───────────────────────────────────────────────────

--- Each camera is inserted into every grid cell its capture radius touches,
--- so a vehicle only ever tests the cameras in its own cell. Cost stays
--- flat no matter how many cameras the config grows to.
local function BuildIndex()
    CELL = Config.Detection.cellSize
    -- Bucket footprint must cover whichever detection radius is larger —
    -- ALPR's and speed's are independently configured, and a camera under-
    -- registered in the grid would silently miss detections at the edge.
    -- The actual per-mode hit test below still uses each mode's own exact
    -- radius; this only controls which cells a camera is discoverable in.
    RADIUS = math.max(Config.Detection.captureRadius, Config.SpeedDetection.captureRadius)

    if CELL < RADIUS * 2 then
        CELL = RADIUS * 2
        print(('^3[%s]^7 cellSize was below 2x captureRadius; raised to %.1f'):format(
            Config.ResourceName, CELL))
    end

    for _, cfg in ipairs(Config.Cameras) do
        if cfg.enabled ~= false then
            cameraById[cfg.id] = cfg

            local c = cfg.coords
            local minX, maxX = math.floor((c.x - RADIUS) / CELL), math.floor((c.x + RADIUS) / CELL)
            local minY, maxY = math.floor((c.y - RADIUS) / CELL), math.floor((c.y + RADIUS) / CELL)

            for cx = minX, maxX do
                for cy = minY, maxY do
                    local key = ('%d:%d'):format(cx, cy)
                    local bucket = cameraGrid[key]

                    if not bucket then
                        bucket = {}
                        cameraGrid[key] = bucket
                    end

                    bucket[#bucket + 1] = cfg
                end
            end
        end
    end
end

local function CamerasNear(x, y)
    return cameraGrid[('%d:%d'):format(math.floor(x / CELL), math.floor(y / CELL))]
end

local function IsCameraOnline(id)
    local until_ = disabledUntil[id]

    if not until_ then return true end
    if os.time() >= until_ then
        disabledUntil[id] = nil
        return true
    end

    return false
end

local function HasMode(cfg, mode)
    local modes = cfg.modes
    if not modes then return false end

    for i = 1, #modes do
        if modes[i] == mode then return true end
    end

    return false
end

-- Shortest 2D distance from point (px,py) to the segment (ax,ay)->(bx,by).
-- Ported from distortionz_speedcam's client-side version, now run
-- server-side against the server's own cross-tick position samples — a
-- fast pass between two scan ticks still can't tunnel past a camera.
local function DistPointToSeg2D(px, py, ax, ay, bx, by)
    local abx, aby = bx - ax, by - ay
    local ab2 = abx * abx + aby * aby
    local t = 0.0

    if ab2 > 0 then
        t = ((px - ax) * abx + (py - ay) * aby) / ab2
        if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
    end

    local qx, qy = ax + abx * t, ay + aby * t
    local dx, dy = px - qx, py - qy

    return math.sqrt(dx * dx + dy * dy)
end

local function SpeedFromMs(ms)
    if Config.SpeedDetection.unit == 'kmh' then
        return ms * 3.6
    end

    return ms * 2.236936
end

-- ─── Framework bridge ───────────────────────────────────────────────

local function IsQbox()
    return GetResourceState('qbx_core') == 'started'
end

local function GetPlayer(src)
    if not IsQbox() then return nil end

    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok then return player end

    return nil
end

local function GetCitizenId(src)
    local player = GetPlayer(src)

    if player and player.PlayerData then
        return player.PlayerData.citizenid
    end

    return nil
end

--- Officer access. On Qbox this is job + optional on-duty; with no
--- framework it degrades to an ACE so the resource still works standalone.
local function HasAccess(src)
    local player = GetPlayer(src)

    if not player then
        return IsPlayerAceAllowed(src, Config.Access.acePermission)
    end

    local job = player.PlayerData and player.PlayerData.job
    if not job then return false end

    local allowed = false
    for _, name in ipairs(Config.Access.jobs) do
        if job.name == name then
            allowed = true
            break
        end
    end

    if not allowed then return false end
    if Config.Access.requireOnDuty and job.onduty == false then return false end

    return true
end

local function GetOfficers()
    local officers = {}

    for _, sid in ipairs(GetPlayers()) do
        local src = tonumber(sid)

        if src and HasAccess(src) then
            officers[#officers + 1] = src
        end
    end

    return officers
end

-- ─── Notify bridge ──────────────────────────────────────────────────

local function NotifyMany(targets, message, status, duration)
    if #targets == 0 then return end

    if Config.Notify.useDistortionzNotify
        and GetResourceState('distortionz_notify') == 'started' then
        local ok = pcall(function()
            exports['distortionz_notify']:NotifyMany(
                targets, message, status or 'police', duration or 9000, Config.Notify.title)
        end)

        if ok then return end
    end

    for i = 1, #targets do
        TriggerClientEvent('distortionz_flock:client:notify', targets[i],
            message, status or 'police', duration or 9000)
    end
end

local function NotifyOne(src, message, status, duration)
    if Config.Notify.useDistortionzNotify
        and GetResourceState('distortionz_notify') == 'started' then
        local ok = pcall(function()
            exports['distortionz_notify']:Notify(
                src, message, status or 'info', duration or 5000, Config.Notify.title)
        end)

        if ok then return end
    end

    TriggerClientEvent('distortionz_flock:client:notify', src,
        message, status or 'info', duration or 5000)
end

-- ─── Persistence ────────────────────────────────────────────────────

--- Reads are queued and written as one multi-row INSERT. At rush hour a
--- per-read query would mean hundreds of round trips a minute for data
--- nobody reads in real time.
local function FlushReads()
    local pending = readQueue
    if #pending == 0 then return end

    readQueue = {}

    local placeholders, values = {}, {}

    for i = 1, #pending do
        local row = pending[i]
        placeholders[#placeholders + 1] = '(?, ?, ?, ?, FROM_UNIXTIME(?))'
        values[#values + 1] = row.cameraId
        values[#values + 1] = row.cameraLabel
        values[#values + 1] = row.plate
        values[#values + 1] = row.citizenid
        values[#values + 1] = row.at
    end

    local query = ('INSERT INTO `distortionz_flock_reads` '
        .. '(`camera_id`, `camera_label`, `plate`, `citizenid`, `created_at`) VALUES %s')
        :format(table.concat(placeholders, ','))

    exports.oxmysql:execute(query, values)

    DebugPrint(('Flushed %d read(s).'):format(#pending))
end

local function PruneOldReads()
    local days = tonumber(Config.Database.retentionDays) or 0
    if days <= 0 then return end

    exports.oxmysql:execute(
        'DELETE FROM `distortionz_flock_reads` WHERE `created_at` < (NOW() - INTERVAL ? DAY)',
        { days })
end

local function LoadHotlist()
    exports.oxmysql:execute(
        'SELECT `plate`, `reason`, `added_by` FROM `distortionz_flock_hotlist` WHERE `active` = 1',
        {},
        function(rows)
            hotlist = {}

            for i = 1, #(rows or {}) do
                local row = rows[i]
                hotlist[row.plate] = { reason = row.reason, added_by = row.added_by }
            end

            print(('^5[%s]^7 ^2Hotlist loaded — %d plate(s).^7'):format(
                Config.ResourceName, #(rows or {})))
        end)
end

local function Audit(src, action, detail)
    local player = GetPlayer(src)
    local name   = src > 0 and GetPlayerName(src) or 'CONSOLE'

    if player and player.PlayerData and player.PlayerData.charinfo then
        local ci = player.PlayerData.charinfo
        name = ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', '')
    end

    exports.oxmysql:execute(
        'INSERT INTO `distortionz_flock_audit` (`officer_cid`, `officer_name`, `action`, `detail`) '
        .. 'VALUES (?, ?, ?, ?)',
        { GetCitizenId(src), name, action, detail })
end

-- ─── Plate helpers ──────────────────────────────────────────────────

local function NormalizePlate(plate)
    if type(plate) ~= 'string' then return nil end

    plate = plate:upper():gsub('%s+', '')
    if plate == '' or #plate > 12 then return nil end

    -- Plates are alphanumeric only; anything else is a malformed or
    -- hand-crafted value and must never reach a query.
    if plate:find('[^%u%d]') then return nil end

    return plate
end

local function ReadPlate(vehicle)
    local ok, plate = pcall(GetVehicleNumberPlateText, vehicle)
    if not ok or not plate then return nil end

    return NormalizePlate(plate)
end

-- ─── Speed camera fine ──────────────────────────────────────────────
-- Ported from distortionz_speedcam, unchanged apart from Collect's nil-
-- player guard (this resource works standalone, without qbx_core).

local function ComputeFine(speed, limit)
    local over = speed - limit
    if over <= 0 then return 0 end

    local f = Config.Fine.base + (Config.Fine.perUnitOver * over)
    f = math.floor(f + 0.5)

    if f < Config.Fine.min then f = Config.Fine.min end
    if f > Config.Fine.max then f = Config.Fine.max end

    return f
end

--- Returns the account actually billed ('bank'/'cash'), or nil if no
--- qbx_core (standalone) or neither account could cover it.
local function Collect(player, amount)
    if not player then return nil end

    local paid = player.Functions.RemoveMoney(Config.Fine.account, amount, Config.Fine.reason)
    if paid then return Config.Fine.account end

    if Config.Fine.fallback then
        paid = player.Functions.RemoveMoney(Config.Fine.fallback, amount, Config.Fine.reason)
        if paid then return Config.Fine.fallback end
    end

    return nil
end

--- Chance-based dispatch ping for a speeding violation — distinct from
--- FireHit (hotlist/BOLO), which always fires. Uses GetOfficers() like
--- everything else here, so "who's police" is one definition resource-wide.
local function FireSpeedAlert(cfg, speed, limit, plate)
    if not Config.SpeedAlert.enabled then return end
    if math.random() > (Config.SpeedAlert.chance or 1.0) then return end

    local c = cfg.coords
    local label = ('%s — plate %s'):format(Config.SpeedAlert.label, plate ~= '' and plate or 'UNKNOWN')

    if Config.SpeedAlert.useCad and GetResourceState('distortionz_cad') == 'started' then
        pcall(function()
            exports['distortionz_cad']:AddCall({
                code     = Config.SpeedAlert.code,
                title    = label,
                location = cfg.label or cfg.id,
                coords   = { x = c.x, y = c.y, z = c.z },
                priority = Config.SpeedAlert.cadPriority or 3,
            })
        end)
    end

    local delay = math.random(Config.SpeedAlert.delayMs.min or 1500, Config.SpeedAlert.delayMs.max or 4000)

    SetTimeout(delay, function()
        local officers = GetOfficers()
        if #officers == 0 then return end

        NotifyMany(officers, ('%s — %s (%d/%d %s)'):format(
            Config.SpeedAlert.code, label, speed, limit, Config.SpeedDetection.unit), 'police', 9000)

        for i = 1, #officers do
            TriggerClientEvent('distortionz_flock:client:hit', officers[i], {
                label         = label,
                coords        = { x = c.x, y = c.y, z = c.z },
                blipTimeoutMs = Config.SpeedAlert.blipTimeoutMs,
            })
        end
    end)
end

--- Server-authoritative cooldown + fine + persistence for one speeding
--- pass. plate/speed/limit are all derived by the server itself — see
--- ScanVehicle below — never taken from the client.
local function RecordSpeedViolation(cfg, plate, citizenid, src, speed, limit)
    local now = os.time()
    local key = ('%s|%s'):format(cfg.id, plate)

    if (now - (lastFine[key] or 0)) < Config.SpeedDetection.cooldownSeconds then
        return
    end

    lastFine[key] = now

    -- Fire the camera flash immediately — this is the "caught in the act"
    -- moment, it shouldn't wait on the fine/billing work below. Broadcasts
    -- to everyone (DrawLightWithRange only actually renders for whoever's
    -- close enough to see it), not just the driver.
    local cc = cfg.coords
    TriggerClientEvent('distortionz_flock:client:cameraFlash', -1, { x = cc.x, y = cc.y, z = cc.z })

    local fine      = ComputeFine(speed, limit)
    local player    = GetPlayer(src)
    local paidFrom  = fine > 0 and Collect(player, fine) or nil
    local unit      = Config.SpeedDetection.unit

    exports.oxmysql:execute(
        'INSERT INTO `distortionz_flock_speed_violations` '
        .. '(`camera_id`, `camera_label`, `plate`, `citizenid`, `speed`, `speed_limit`, `fine_amount`, `paid_from`) '
        .. 'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { cfg.id, cfg.label or cfg.id, plate, citizenid, speed, limit, fine, paidFrom })

    if fine > 0 then
        if paidFrom then
            NotifyOne(src, ('Speed camera: %d %s in a %d %s zone. Fined $%d from %s.'):format(
                speed, unit, limit, unit, fine, paidFrom), 'error', 8000)
        elseif player then
            NotifyOne(src, ('Speed camera: %d %s in a %d %s zone. Unpaid fine of $%d — flagged.'):format(
                speed, unit, limit, unit, fine), 'error', 8000)
        else
            NotifyOne(src, ('Speed camera: %d %s in a %d %s zone. Logged — no billing available.'):format(
                speed, unit, limit, unit), 'error', 8000)
        end
    end

    DebugPrint(('Speed violation %s plate=%s %d/%d %s = $%d (%s)'):format(
        cfg.id, plate, speed, limit, unit, fine, paidFrom or 'UNPAID'))

    FireSpeedAlert(cfg, speed, limit, plate)
end

-- ─── Hotlist alert ──────────────────────────────────────────────────

--- Single delivery path for both hotlist and BOLO hits — a hit is a hit.
--- `entry` carries the reason plus optional per-call overrides (code/
--- label/blipTimeoutMs/useCad/cadPriority/enabled); anything it doesn't
--- set falls back to Config.Alert, so the existing hotlist call site
--- (which never set these) behaves exactly as before.
local function FireHit(cfg, plate, entry)
    local enabled = entry.enabled
    if enabled == nil then enabled = Config.Alert.enabled end
    if not enabled then return end

    local code          = entry.code or Config.Alert.code
    local label         = entry.label or Config.Alert.label
    local blipTimeoutMs = entry.blipTimeoutMs or Config.Alert.blipTimeoutMs
    local useCad         = entry.useCad
    if useCad == nil then useCad = Config.Alert.useCad end
    local cadPriority    = entry.cadPriority or Config.Alert.cadPriority

    local c = cfg.coords

    if useCad and GetResourceState('distortionz_cad') == 'started' then
        pcall(function()
            exports['distortionz_cad']:AddCall({
                code     = code,
                title    = ('%s — plate %s'):format(label, plate),
                location = cfg.label or cfg.id,
                coords   = { x = c.x, y = c.y, z = c.z },
                priority = cadPriority or 1,
            })
        end)
    end

    local delay = math.random(Config.Alert.delayMs.min or 800, Config.Alert.delayMs.max or 2000)

    SetTimeout(delay, function()
        local officers = GetOfficers()
        if #officers == 0 then return end

        NotifyMany(officers, ('%s — plate %s at %s (%s)'):format(
            code,
            plate,
            cfg.label or cfg.id,
            entry.reason or 'no reason given'), 'police', 10000)

        for i = 1, #officers do
            TriggerClientEvent('distortionz_flock:client:hit', officers[i], {
                label         = ('%s — %s'):format(label, plate),
                coords        = { x = c.x, y = c.y, z = c.z },
                blipTimeoutMs = blipTimeoutMs,
            })
        end
    end)
end

-- ─── Scan ───────────────────────────────────────────────────────────

local function RecordRead(cfg, plate, citizenid)
    local now = os.time()
    local key = ('%s|%s'):format(cfg.id, plate)

    if (now - (lastRead[key] or 0)) < Config.CooldownSeconds then
        return false
    end

    lastRead[key] = now

    readQueue[#readQueue + 1] = {
        cameraId    = cfg.id,
        cameraLabel = cfg.label or cfg.id,
        plate       = plate,
        citizenid   = citizenid,
        at          = now,
    }

    DebugPrint(('Read %s at %s'):format(plate, cfg.id))

    local entry = hotlist[plate]
    if entry then
        FireHit(cfg, plate, entry)
    end

    -- Independent of the hotlist check above — a plate can be both
    -- hotlisted and BOLO'd, and both alerts should fire. Restricted to
    -- type='Vehicle' BOLOs on CAD's side (see CheckVehicleBolo), so a
    -- Person BOLO's free-text reference field can't false-positive here.
    if Config.Bolo.enabled and GetResourceState('distortionz_cad') == 'started' then
        local ok, bolo = pcall(function()
            return exports['distortionz_cad']:CheckVehicleBolo(plate)
        end)

        if ok and bolo then
            FireHit(cfg, plate, {
                reason        = bolo.title or bolo.details or 'Active BOLO',
                code          = Config.Bolo.code,
                label         = Config.Bolo.label,
                blipTimeoutMs = Config.Bolo.blipTimeoutMs,
                useCad        = Config.Bolo.useCad,
                cadPriority   = Config.Bolo.cadPriority,
                enabled       = Config.Bolo.enabled,
            })
        end
    end

    return true
end

--- One pass over every camera near this vehicle, doing whichever of
--- ALPR/speed each camera is configured for (HasMode). `prevState` is
--- this vehicle's `src`'s last-tick sample (nil on first sighting or a
--- requireOccupant=false pass); `canSpeedTest` is false for a passenger
--- when Config.SpeedDetection.driverOnly is set, and always false in the
--- requireOccupant=false branch (no stable src to bill or track there —
--- a documented limitation, not a silent gap). Returns this tick's
--- position sample (or nil if canSpeedTest is false) for the caller to
--- store as next tick's prevState.
local function ScanVehicle(vehicle, src, citizenid, prevState, canSpeedTest)
    if not DoesEntityExist(vehicle) then return nil end

    local pos    = GetEntityCoords(vehicle)
    local nearby = CamerasNear(pos.x, pos.y)

    local curState, ps
    if canSpeedTest then
        local netId = NetworkGetNetworkIdFromEntity(vehicle)
        curState = { netId = netId, x = pos.x, y = pos.y, z = pos.z }
        -- First-ever sample of this src's vehicle, or a mid-tick vehicle
        -- swap: treat as a zero-length segment (point test) rather than
        -- skipping the tick entirely — mirrors distortionz_speedcam's
        -- original "prev = lastPos or cur" first-sample behavior.
        ps = (prevState and prevState.netId == netId) and prevState or curState
    end

    if not nearby then return curState end

    local plate -- read lazily, at most once, shared by both modes below

    for i = 1, #nearby do
        local cfg = nearby[i]

        if IsCameraOnline(cfg.id) then
            local c = cfg.coords

            if HasMode(cfg, 'alpr') then
                local dx, dy = pos.x - c.x, pos.y - c.y
                local horiz  = math.sqrt(dx * dx + dy * dy)

                if horiz <= Config.Detection.captureRadius and math.abs(pos.z - c.z) <= Config.Detection.verticalBand then
                    plate = plate or ReadPlate(vehicle)
                    if plate then RecordRead(cfg, plate, citizenid) end
                end
            end

            if canSpeedTest and cfg.limit and HasMode(cfg, 'speed') then
                -- Segment-tested against the path travelled since last
                -- tick, not just the current point — a fast pass can't
                -- tunnel between two 1-second samples.
                local horiz = DistPointToSeg2D(c.x, c.y, ps.x, ps.y, pos.x, pos.y)
                local vert  = math.min(math.abs(pos.z - c.z), math.abs(ps.z - c.z))

                if Config.Debug and horiz <= Config.SpeedDetection.captureRadius * 3.0 then
                    DebugPrint(('Near speed cam %s: h=%.1f v=%.1f speed=%.0f limit=%d'):format(
                        cfg.id, horiz, vert, SpeedFromMs(GetEntitySpeed(vehicle)), cfg.limit))
                end

                if horiz <= Config.SpeedDetection.captureRadius and vert <= Config.SpeedDetection.verticalBand then
                    local speedVal = SpeedFromMs(GetEntitySpeed(vehicle))
                    local trip     = cfg.limit + (Config.SpeedDetection.tolerance or 0)

                    if speedVal > trip then
                        plate = plate or ReadPlate(vehicle)
                        if plate then
                            RecordSpeedViolation(cfg, plate, citizenid, src, math.floor(speedVal + 0.5), cfg.limit)
                        end
                    end
                end
            end
        end
    end

    return curState
end

CreateThread(function()
    while true do
        Wait(Config.Detection.intervalMs)

        if Config.Detection.requireOccupant then
            local newVehState = {}

            -- Only players' vehicles can matter: ambient NPC traffic is
            -- client-side and never networked to the server anyway.
            for _, sid in ipairs(GetPlayers()) do
                local src = tonumber(sid)
                local ped = src and GetPlayerPed(src)

                if ped and ped ~= 0 then
                    local veh = GetVehiclePedIsIn(ped)

                    if veh and veh ~= 0 then
                        local canSpeedTest = not Config.SpeedDetection.driverOnly
                            or GetPedInVehicleSeat(veh, -1) == ped

                        local state = ScanVehicle(veh, src, GetCitizenId(src), lastVehState[src], canSpeedTest)
                        if state then newVehState[src] = state end
                    end
                end
            end

            -- Wholesale replace, not mutate-and-prune: a disconnected
            -- player, a parked car, or someone who got out simply isn't
            -- written into the fresh table and disappears with it.
            lastVehState = newVehState
        else
            -- No stable src here to bill or track across ticks, so speed
            -- detection is skipped entirely in this mode — ALPR (which
            -- doesn't need a src) still runs normally.
            for _, veh in ipairs(GetAllVehicles()) do
                ScanVehicle(veh, nil, nil, nil, false)
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(Config.Database.flushIntervalMs)
        FlushReads()
    end
end)

-- ─── Rate limit ─────────────────────────────────────────────────────

local function TakeSearchToken(src)
    local limit = tonumber(Config.Access.searchesPerMinute) or 10
    local now   = os.time()
    local stamps = searchStamps[src]

    if not stamps then
        stamps = {}
        searchStamps[src] = stamps
    end

    local kept = {}
    for i = 1, #stamps do
        if now - stamps[i] < 60 then
            kept[#kept + 1] = stamps[i]
        end
    end

    searchStamps[src] = kept

    if #kept >= limit then return false end

    kept[#kept + 1] = now

    return true
end

-- ─── Officer API ────────────────────────────────────────────────────

lib.callback.register('distortionz_flock:server:searchPlate', function(source, plate)
    if not HasAccess(source) then return nil end

    if not TakeSearchToken(source) then
        NotifyOne(source, 'Too many searches. Slow down.', 'error')
        return nil
    end

    plate = NormalizePlate(plate)
    if not plate then
        NotifyOne(source, 'Invalid plate.', 'error')
        return nil
    end

    -- FlushReads first so a plate that just passed a camera is findable.
    FlushReads()

    Audit(source, 'search', plate)

    local rows = exports.oxmysql:executeSync(
        'SELECT `camera_label`, `plate`, `created_at` FROM `distortionz_flock_reads` '
        .. 'WHERE `plate` = ? ORDER BY `created_at` DESC LIMIT 20',
        { plate })

    return {
        plate   = plate,
        hotlist = hotlist[plate],
        reads   = rows or {},
    }
end)

lib.callback.register('distortionz_flock:server:getHotlist', function(source)
    if not HasAccess(source) then return nil end

    local out = {}
    for plate, entry in pairs(hotlist) do
        out[#out + 1] = { plate = plate, reason = entry.reason, added_by = entry.added_by }
    end

    table.sort(out, function(a, b) return a.plate < b.plate end)

    return out
end)

lib.callback.register('distortionz_flock:server:addHotlist', function(source, plate, reason)
    if not HasAccess(source) then return false end

    plate = NormalizePlate(plate)
    if not plate then return false end

    reason = tostring(reason or 'No reason given'):sub(1, 200)

    local officer = GetPlayerName(source) or 'Unknown'

    exports.oxmysql:executeSync(
        'INSERT INTO `distortionz_flock_hotlist` (`plate`, `reason`, `added_by`, `active`) '
        .. 'VALUES (?, ?, ?, 1) ON DUPLICATE KEY UPDATE '
        .. '`reason` = VALUES(`reason`), `added_by` = VALUES(`added_by`), `active` = 1',
        { plate, reason, officer })

    hotlist[plate] = { reason = reason, added_by = officer }

    Audit(source, 'hotlist_add', ('%s — %s'):format(plate, reason))

    return true
end)

lib.callback.register('distortionz_flock:server:removeHotlist', function(source, plate)
    if not HasAccess(source) then return false end

    plate = NormalizePlate(plate)
    if not plate then return false end

    exports.oxmysql:executeSync(
        'UPDATE `distortionz_flock_hotlist` SET `active` = 0 WHERE `plate` = ?', { plate })

    hotlist[plate] = nil

    Audit(source, 'hotlist_remove', plate)

    return true
end)

lib.callback.register('distortionz_flock:server:recentHits', function(source)
    if not HasAccess(source) then return nil end

    FlushReads()

    local rows = exports.oxmysql:executeSync(
        'SELECT r.`plate`, r.`camera_label`, r.`created_at` '
        .. 'FROM `distortionz_flock_reads` r '
        .. 'INNER JOIN `distortionz_flock_hotlist` h ON h.`plate` = r.`plate` AND h.`active` = 1 '
        .. 'ORDER BY r.`created_at` DESC LIMIT 25', {})

    return rows or {}
end)

--- Camera list for the officer map/menu. Coords come from the server's own
--- config, never from the client.
--- Shared by the client callback and the cross-resource export below, so
--- distortionz_cad gets the exact same access-gated view a flock officer
--- would see — no separate, potentially-looser copy of this logic.
local function BuildCameraList(source)
    if not HasAccess(source) then return nil end

    local out = {}

    for _, cfg in ipairs(Config.Cameras) do
        if cfg.enabled ~= false then
            out[#out + 1] = {
                id      = cfg.id,
                label   = cfg.label or cfg.id,
                coords  = { x = cfg.coords.x, y = cfg.coords.y, z = cfg.coords.z },
                online  = IsCameraOnline(cfg.id),
            }
        end
    end

    return out
end

lib.callback.register('distortionz_flock:server:getCameras', function(source)
    return BuildCameraList(source)
end)

-- ─── Counterplay ────────────────────────────────────────────────────

RegisterNetEvent('distortionz_flock:server:tamper', function(cameraId)
    local src = source

    if not Config.Counterplay.enabled then return end
    if type(cameraId) ~= 'string' then return end

    local cfg = cameraById[cameraId]
    if not cfg then return end

    if not IsCameraOnline(cameraId) then
        NotifyOne(src, 'This camera is already offline.', 'error')
        return
    end

    -- The client only ever names a camera. Position is verified against the
    -- server's own coords, so a spoofed id from across the map is dropped.
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local pos = GetEntityCoords(ped)
    local c   = cfg.coords
    local dx, dy, dz = pos.x - c.x, pos.y - c.y, pos.z - c.z

    if math.sqrt(dx * dx + dy * dy + dz * dz) > (Config.Counterplay.useRadius + 3.0) then
        DebugPrint(('Rejected tamper from %s — out of range of %s'):format(src, cameraId))
        return
    end

    if Config.Counterplay.item then
        local has = false

        if GetResourceState('ox_inventory') == 'started' then
            local ok, count = pcall(function()
                return exports.ox_inventory:GetItemCount(src, Config.Counterplay.item)
            end)
            has = ok and (count or 0) > 0
        end

        if not has then
            NotifyOne(src, 'You need the right tool for this.', 'error')
            return
        end

        if Config.Counterplay.consumeItem then
            pcall(function()
                exports.ox_inventory:RemoveItem(src, Config.Counterplay.item, 1)
            end)
        end
    end

    disabledUntil[cameraId] = os.time() + Config.Counterplay.downtime

    NotifyOne(src, ('Camera disabled for %d minutes.'):format(
        math.floor(Config.Counterplay.downtime / 60)), 'success', 7000)

    TriggerClientEvent('distortionz_flock:client:cameraState', -1, cameraId, false)

    SetTimeout(Config.Counterplay.downtime * 1000, function()
        TriggerClientEvent('distortionz_flock:client:cameraState', -1, cameraId, true)
    end)

    if math.random() <= (Config.Counterplay.alertChance or 0) then
        local officers = GetOfficers()

        if #officers > 0 then
            NotifyMany(officers, ('%s — %s'):format(
                Config.Counterplay.alertCode, cfg.label or cfg.id), 'police', 9000)

            for i = 1, #officers do
                TriggerClientEvent('distortionz_flock:client:hit', officers[i], {
                    label         = Config.Counterplay.alertLabel,
                    coords        = { x = c.x, y = c.y, z = c.z },
                    blipTimeoutMs = Config.Alert.blipTimeoutMs,
                })
            end
        end

        if Config.Alert.useCad and GetResourceState('distortionz_cad') == 'started' then
            pcall(function()
                exports['distortionz_cad']:AddCall({
                    code     = Config.Counterplay.alertCode,
                    title    = Config.Counterplay.alertLabel,
                    location = cfg.label or cfg.id,
                    coords   = { x = c.x, y = c.y, z = c.z },
                    priority = 2,
                })
            end)
        end
    end
end)

-- ─── Access probe for the client ────────────────────────────────────

lib.callback.register('distortionz_flock:server:hasAccess', function(source)
    return HasAccess(source)
end)

-- ─── Housekeeping ───────────────────────────────────────────────────

AddEventHandler('playerDropped', function()
    searchStamps[source] = nil
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    FlushReads()
end)

CreateThread(function()
    BuildIndex()

    -- oxmysql needs a moment before the first query on a cold boot.
    Wait(2000)

    LoadHotlist()
    PruneOldReads()

    print(('^5[%s]^7 ^2v%s loaded — cameras=%d interval=%dms retention=%sd^7'):format(
        Config.ResourceName,
        Config.CurrentVersion,
        #Config.Cameras,
        Config.Detection.intervalMs,
        tostring(Config.Database.retentionDays)))

    while true do
        Wait(6 * 60 * 60 * 1000)
        PruneOldReads()
    end
end)
