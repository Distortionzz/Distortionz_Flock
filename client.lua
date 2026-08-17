-- =====================================================================
--  Distortionz Flock — client
--  Cosmetic and UI only. The client never detects, reads, or reports a
--  plate; it spawns props, draws blips, and asks the server questions.
-- =====================================================================

local cameras     = {}      -- [id] = { prop, pole, blip, cfg }
local cameraState = {}      -- [id] = online boolean
local hasAccess   = false

local function DebugPrint(message)
    if Config.Debug then
        print(('[%s:client] %s'):format(Config.ResourceName, message))
    end
end

-- ─── Notify wrapper ─────────────────────────────────────────────────

local function Notify(message, status, duration)
    status   = status or 'info'
    duration = duration or 5000

    if Config.Notify.useDistortionzNotify
        and GetResourceState('distortionz_notify') == 'started' then
        local ok = pcall(function()
            exports['distortionz_notify']:Notify(message, status, duration, Config.Notify.title)
        end)

        if ok then return end
    end

    lib.notify({
        title       = Config.Notify.title,
        description = message,
        type        = status == 'police' and 'inform' or status,
        duration    = duration,
    })
end

RegisterNetEvent('distortionz_flock:client:notify', function(message, status, duration)
    Notify(message, status, duration)
end)

-- ─── Entity helpers ─────────────────────────────────────────────────

local function LoadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) then return nil end

    RequestModel(hash)

    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(hash) do
        Wait(25)
        if GetGameTimer() > deadline then return nil end
    end

    return hash
end

local function DeleteEntitySafe(entity)
    if entity and DoesEntityExist(entity) then
        SetEntityAsMissionEntity(entity, true, true)
        DeleteEntity(entity)
    end
end

local function RemoveBlipSafe(blip)
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
end

-- ─── Camera spawn ───────────────────────────────────────────────────

local function CreateProp(model, x, y, z, heading)
    local hash = LoadModel(model)
    if not hash then return nil end

    local prop = CreateObject(hash, x, y, z, false, false, false)
    SetEntityHeading(prop, heading or 0.0)

    if Config.Prop.freeze     then FreezeEntityPosition(prop, true) end
    if Config.Prop.invincible then SetEntityInvincible(prop, true) end

    SetModelAsNoLongerNeeded(hash)

    return prop
end

local function SpawnCamera(cfg)
    if cfg.enabled == false then return end

    local c = cfg.coords

    -- Pole-mounted: the configured Z is used verbatim, never ground-snapped.
    local prop = CreateProp(cfg.model or Config.Prop.model, c.x, c.y, c.z, c.w)
    if not prop then
        DebugPrint(('Prop load failed for %s'):format(cfg.id))
        return
    end

    local poleModel = cfg.pole
    if poleModel == nil then poleModel = Config.Prop.pole end

    local pole
    if poleModel then
        pole = CreateProp(poleModel, c.x, c.y, c.z - (Config.Prop.poleOffset or 2.2), c.w)
    end

    cameras[cfg.id] = { prop = prop, pole = pole, blip = nil, cfg = cfg }
end

local function ApplyBlip(entry)
    local cfg = entry.cfg
    local show = Config.Blip.enabled and (not Config.Blip.policeOnly or hasAccess)

    if not show then
        RemoveBlipSafe(entry.blip)
        entry.blip = nil
        return
    end

    if entry.blip and DoesBlipExist(entry.blip) then return end

    local c = cfg.coords
    local blip = AddBlipForCoord(c.x, c.y, c.z)

    SetBlipSprite(blip, Config.Blip.sprite or 184)
    SetBlipColour(blip, cameraState[cfg.id] == false and 1 or (Config.Blip.color or 3))
    SetBlipScale(blip, Config.Blip.scale or 0.7)
    SetBlipAsShortRange(blip, Config.Blip.shortRange ~= false)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(cfg.label or Config.Blip.label or 'Flock Camera')
    EndTextCommandSetBlipName(blip)

    entry.blip = blip
end

local function RefreshBlips()
    for _, entry in pairs(cameras) do
        ApplyBlip(entry)
    end
end

RegisterNetEvent('distortionz_flock:client:cameraState', function(cameraId, online)
    cameraState[cameraId] = online

    local entry = cameras[cameraId]
    if entry and entry.blip and DoesBlipExist(entry.blip) then
        SetBlipColour(entry.blip, online and (Config.Blip.color or 3) or 1)
    end
end)

-- ─── Hotlist hit alert ──────────────────────────────────────────────

RegisterNetEvent('distortionz_flock:client:hit', function(payload)
    if type(payload) ~= 'table' or not payload.coords then return end

    local blip = AddBlipForCoord(payload.coords.x, payload.coords.y, payload.coords.z)

    SetBlipSprite(blip, 184)
    SetBlipColour(blip, 3)
    SetBlipScale(blip, 0.9)
    SetBlipAsShortRange(blip, false)
    SetBlipFlashes(blip, true)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(payload.label or 'Flock hit')
    EndTextCommandSetBlipName(blip)

    SetTimeout(payload.blipTimeoutMs or 60000, function()
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end)
end)

-- ─── Officer UI ─────────────────────────────────────────────────────

local function FormatWhen(value)
    -- oxmysql hands back either a formatted string or an epoch-ms number
    -- depending on driver settings; render both without lying about it.
    if type(value) == 'number' then
        return os.date('%Y-%m-%d %H:%M', math.floor(value / 1000))
    end

    return tostring(value or '?')
end

local function ShowPlateResult(result)
    if not result then return end

    local options = {}

    if result.hotlist then
        options[#options + 1] = {
            title       = 'ON HOTLIST',
            description = result.hotlist.reason or 'No reason given',
            icon        = 'triangle-exclamation',
            iconColor   = 'red',
            readOnly    = true,
        }
    end

    if #result.reads == 0 then
        options[#options + 1] = {
            title       = 'No sightings',
            description = 'This plate has not passed a camera in the retention window.',
            readOnly    = true,
        }
    else
        for i = 1, #result.reads do
            local row = result.reads[i]
            options[#options + 1] = {
                title       = row.camera_label,
                description = FormatWhen(row.created_at),
                icon        = 'camera',
                readOnly    = true,
            }
        end
    end

    lib.registerContext({
        id      = 'flock_plate_result',
        title   = ('Plate %s'):format(result.plate),
        menu    = 'flock_main',
        options = options,
    })

    lib.showContext('flock_plate_result')
end

local function SearchPlate()
    local input = lib.inputDialog('Plate search', {
        { type = 'input', label = 'Plate', required = true, max = 12 },
    })

    if not input then return end

    local result = lib.callback.await('distortionz_flock:server:searchPlate', false, input[1])

    if not result then
        Notify('Search failed or was denied.', 'error')
        return
    end

    ShowPlateResult(result)
end

local function AddHotlist()
    local input = lib.inputDialog('Add to hotlist', {
        { type = 'input', label = 'Plate',  required = true, max = 12 },
        { type = 'input', label = 'Reason', required = true, max = 200 },
    })

    if not input then return end

    local ok = lib.callback.await('distortionz_flock:server:addHotlist', false, input[1], input[2])

    Notify(ok and 'Plate added to the hotlist.' or 'Failed to add plate.',
        ok and 'success' or 'error')
end

local function ShowHotlist()
    local rows = lib.callback.await('distortionz_flock:server:getHotlist', false)
    if not rows then return end

    local options = {}

    if #rows == 0 then
        options[1] = { title = 'Hotlist is empty', readOnly = true }
    else
        for i = 1, #rows do
            local row = rows[i]
            options[#options + 1] = {
                title       = row.plate,
                description = ('%s — added by %s'):format(
                    row.reason or 'No reason', row.added_by or 'Unknown'),
                icon        = 'car',
                onSelect    = function()
                    local confirm = lib.alertDialog({
                        header   = ('Remove %s?'):format(row.plate),
                        content  = 'This clears the plate from the hotlist.',
                        centered = true,
                        cancel   = true,
                    })

                    if confirm ~= 'confirm' then return end

                    local ok = lib.callback.await(
                        'distortionz_flock:server:removeHotlist', false, row.plate)

                    Notify(ok and 'Plate removed.' or 'Failed to remove plate.',
                        ok and 'success' or 'error')
                end,
            }
        end
    end

    lib.registerContext({
        id      = 'flock_hotlist',
        title   = 'Flock — Hotlist',
        menu    = 'flock_main',
        options = options,
    })

    lib.showContext('flock_hotlist')
end

local function ShowRecentHits()
    local rows = lib.callback.await('distortionz_flock:server:recentHits', false)
    if not rows then return end

    local options = {}

    if #rows == 0 then
        options[1] = { title = 'No recent hits', readOnly = true }
    else
        for i = 1, #rows do
            local row = rows[i]
            options[#options + 1] = {
                title       = row.plate,
                description = ('%s — %s'):format(row.camera_label, FormatWhen(row.created_at)),
                icon        = 'triangle-exclamation',
                iconColor   = 'red',
                readOnly    = true,
            }
        end
    end

    lib.registerContext({
        id      = 'flock_hits',
        title   = 'Flock — Recent Hits',
        menu    = 'flock_main',
        options = options,
    })

    lib.showContext('flock_hits')
end

local function ShowCameras()
    local rows = lib.callback.await('distortionz_flock:server:getCameras', false)
    if not rows then return end

    local options = {}

    for i = 1, #rows do
        local row = rows[i]
        options[#options + 1] = {
            title       = row.label,
            description = row.online and 'Online' or 'OFFLINE — tampered',
            icon        = 'camera',
            iconColor   = row.online and 'green' or 'red',
            onSelect    = function()
                SetNewWaypoint(row.coords.x, row.coords.y)
                Notify(('Waypoint set to %s.'):format(row.label), 'success')
            end,
        }
    end

    lib.registerContext({
        id      = 'flock_cameras',
        title   = 'Flock — Cameras',
        menu    = 'flock_main',
        options = options,
    })

    lib.showContext('flock_cameras')
end

local function OpenMenu()
    if not hasAccess then
        Notify('You do not have access to the Flock system.', 'error')
        return
    end

    lib.registerContext({
        id      = 'flock_main',
        title   = 'Flock ALPR',
        options = {
            { title = 'Plate search',  description = 'Where has a plate been seen?', icon = 'magnifying-glass', onSelect = SearchPlate },
            { title = 'Recent hits',   description = 'Latest hotlist sightings',     icon = 'bell',             onSelect = ShowRecentHits },
            { title = 'Hotlist',       description = 'View and manage flagged plates', icon = 'list',           onSelect = ShowHotlist },
            { title = 'Add to hotlist',description = 'Flag a plate',                 icon = 'plus',             onSelect = AddHotlist },
            { title = 'Cameras',       description = 'Camera status and waypoints',  icon = 'video',            onSelect = ShowCameras },
        },
    })

    lib.showContext('flock_main')
end

RegisterCommand('flock', OpenMenu, false)

-- ─── Counterplay ────────────────────────────────────────────────────

local function NearestCamera()
    local pos     = GetEntityCoords(PlayerPedId())
    local best, bestDist

    for id, entry in pairs(cameras) do
        local c    = entry.cfg.coords
        local dist = #(pos - vec3(c.x, c.y, c.z))

        if dist <= Config.Counterplay.useRadius and (not bestDist or dist < bestDist) then
            best, bestDist = id, dist
        end
    end

    return best
end

RegisterCommand('flocktamper', function()
    if not Config.Counterplay.enabled then return end

    local cameraId = NearestCamera()
    if not cameraId then
        Notify('No camera within reach.', 'error')
        return
    end

    if cameraState[cameraId] == false then
        Notify('This camera is already offline.', 'error')
        return
    end

    if lib.progressBar({
        duration    = Config.Counterplay.duration,
        label       = 'Tampering with camera',
        useWhileDead= false,
        canCancel   = true,
        disable     = { car = true, move = true, combat = true },
        anim        = { dict = 'mini@repair', clip = 'fixing_a_ped' },
    }) then
        TriggerServerEvent('distortionz_flock:server:tamper', cameraId)
    end
end, false)

-- ─── Live camera feed ───────────────────────────────────────────────
-- NUI cannot render the 3D world into a panel, so "live feed" means the
-- only honest thing it can mean: moving the officer's own render camera
-- to the physical camera's fixed position, in real time. distortionz_cad
-- calls StartFeed(id) as an export — this resource owns the whole feed,
-- CAD is just the button that triggers it.

local inFeed             = false
local feedCam            = nil
local feedCameraId       = nil
local feedEnterHealth    = 0
local feedPan             = 0.0   -- current look heading, degrees, wraps 0-360
local feedTilt            = 0.0   -- current look pitch, degrees, clamped
local feedFov             = 50.0  -- current zoom, degrees FOV, clamped (lower = more zoomed in)
local feedTraffic         = {}    -- { {veh=, ped=}, ... } — local-only, despawned on exit

-- ─── CCTV look ──────────────────────────────────────────────────────
-- Everything here is plain 2D draw natives (rects + text), not a
-- SetTimecycleModifier/AnimpostfxPlay asset name — those depend on a
-- specific game asset existing and fail silently if it doesn't. Rects
-- always render, so this can't ship broken.

local function DrawScanline()
    local period = 4000
    local t = (GetGameTimer() % period) / period
    DrawRect(0.5, t, 1.0, 0.003, 255, 255, 255, 26)
end

local function DrawCorner(x, y, flipX, flipY)
    local len, thick = 0.018, 0.0025
    local dx = flipX and -len or len
    local dy = flipY and -len or len
    DrawRect(x + dx / 2, y, math.abs(dx), thick, 225, 29, 42, 200)
    DrawRect(x, y + dy / 2, thick, math.abs(dy), 225, 29, 42, 200)
end

local function DrawFeedHud(label, cameraId, online)
    -- Faint monochrome-green wash over the frame.
    DrawRect(0.5, 0.5, 1.0, 1.0, 20, 35, 20, 26)

    if online then DrawScanline() end

    DrawCorner(0.02, 0.09, false, false)
    DrawCorner(0.98, 0.09, true, false)
    DrawCorner(0.02, 0.94, false, true)
    DrawCorner(0.98, 0.94, true, true)

    DrawRect(0.5, 0.036, 1.0, 0.072, 8, 8, 10, 180)

    if online and (GetGameTimer() % 1000) < 600 then
        DrawRect(0.045, 0.036, 0.012, 0.020, 225, 29, 42, 230)
    end

    SetTextFont(4)
    SetTextScale(0.36, 0.36)
    SetTextColour(255, 255, 255, 230)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName((online and '   REC   ' or '   OFFLINE   ') .. label)
    EndTextCommandDisplayText(0.06, 0.018)

    SetTextFont(4)
    SetTextScale(0.22, 0.22)
    SetTextColour(190, 195, 200, 200)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(cameraId:upper())
    EndTextCommandDisplayText(0.84, 0.022)

    SetTextFont(4)
    SetTextScale(0.26, 0.26)
    SetTextColour(190, 195, 200, 210)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName('FLOCK  —  hold [BACKSPACE] to exit')
    EndTextCommandDisplayText(0.06, 0.895)

    if not online then
        DrawRect(0.5, 0.5, 1.0, 1.0, 6, 6, 8, 150)
        SetTextFont(4)
        SetTextScale(0.6, 0.6)
        SetTextColour(225, 29, 42, 230)
        SetTextOutline()
        SetTextCentre(true)
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName('NO SIGNAL')
        EndTextCommandDisplayText(0.5, 0.48)
        SetTextCentre(false)
    end
end

local function DrawConnectingHud()
    DrawRect(0.5, 0.5, 1.0, 1.0, 6, 6, 8, 200)
    SetTextFont(4)
    SetTextScale(0.4, 0.4)
    SetTextColour(190, 195, 200, 220)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName('CONNECTING' .. ('.'):rep(1 + (math.floor(GetGameTimer() / 300) % 3)))
    EndTextCommandDisplayText(0.5, 0.48)
    SetTextCentre(false)
end

-- ─── Feed traffic ───────────────────────────────────────────────────
-- Scripted-in vehicles near the camera, standing in for the ambient
-- traffic GTA won't spawn there on its own (see StartFeed). Every vehicle
-- and driver is created non-networked (the trailing `false, false`), so
-- it exists purely on this client — nobody else's game ever sees it.

local function ClearFeedTraffic()
    for _, e in ipairs(feedTraffic) do
        DeleteEntitySafe(e.ped)
        DeleteEntitySafe(e.veh)
    end
    feedTraffic = {}
end

local function SpawnFeedTraffic(coords)
    local cfg = Config.FeedTraffic
    if not cfg or not cfg.enabled then return end

    for i = 1, cfg.vehicleCount do
        -- Jitter the query point per vehicle so they land at different
        -- road nodes instead of stacking on the single closest one.
        local angle  = math.random() * 2 * math.pi
        local radius = math.random(5, cfg.searchRadius)
        local qx = coords.x + math.cos(angle) * radius
        local qy = coords.y + math.sin(angle) * radius

        local found, pos, heading = GetClosestVehicleNodeWithHeading(qx, qy, coords.z, 1, 3.0, 0)

        if found then
            local model       = cfg.models[math.random(1, #cfg.models)]
            local driverModel = cfg.driverModels[math.random(1, #cfg.driverModels)]

            local vHash = LoadModel(model)
            local dHash = vHash and LoadModel(driverModel)

            if vHash and dHash then
                local veh = CreateVehicle(vHash, pos.x, pos.y, pos.z, heading, false, false)
                SetEntityAsMissionEntity(veh, true, true)
                SetVehicleOnGroundProperly(veh)
                SetModelAsNoLongerNeeded(vHash)

                local driver = CreatePedInsideVehicle(veh, 4, dHash, -1, false, false)
                SetEntityAsMissionEntity(driver, true, true)
                SetModelAsNoLongerNeeded(dHash)
                SetDriverAbility(driver, 1.0)
                SetPedFleeAttributes(driver, 0, false)
                SetBlockingOfNonTemporaryEvents(driver, true)
                TaskVehicleDriveWander(driver, veh, cfg.driveSpeed, cfg.drivingStyle)

                feedTraffic[#feedTraffic + 1] = { veh = veh, ped = driver }
            end
        end
        -- A failed node lookup just means one fewer vehicle this round —
        -- not worth retrying, the feed still works fine with less traffic.
    end
end

local function ExitFeed()
    if not inFeed then return end
    inFeed = false
    feedCameraId = nil

    -- Instant cut, no ease — this is a fixed monitor feed, not a flyover.
    -- Easing over distance is exactly what dragged the view across the
    -- whole map on the way out.
    RenderScriptCams(false, false, 0, true, true)
    if feedCam and DoesCamExist(feedCam) then DestroyCam(feedCam, false) end
    feedCam = nil
    ClearFocus()
    ClearFeedTraffic()

    FreezeEntityPosition(PlayerPedId(), false)
    DisplayRadar(true)
    SetPlayerControl(PlayerId(), true, 0)

    if GetResourceState('distortionz_cad') == 'started' then
        pcall(function() exports['distortionz_cad']:ResumeFromFeed() end)
    end
end

--- Called by distortionz_cad's "View Feed" button (same-client export call,
--- no server round trip — the camera prop and coords are already cached
--- locally from spawn).
local function StartFeed(cameraId)
    if inFeed then return end

    local entry = cameras[cameraId]
    if not entry then
        Notify('Unknown camera.', 'error')
        return
    end

    local c = entry.cfg.coords

    inFeed          = true
    feedCameraId    = cameraId
    -- Captured on entry so any damage taken while "at the terminal" kicks
    -- the officer straight out — the ped stays fully visible and
    -- vulnerable at its real location the whole time, so this matters.
    feedEnterHealth = GetEntityHealth(PlayerPedId())

    FreezeEntityPosition(PlayerPedId(), true)
    DisplayRadar(false)
    SetPlayerControl(PlayerId(), false, 0)

    CreateThread(function()
        -- Static geometry (roads/buildings) streams around a focus point —
        -- this alone is enough for that. Ambient population (the actual
        -- traffic an ALPR camera needs to see) does NOT follow a focus
        -- point, only the real player ped's position, and the ped is
        -- staying put — so traffic is scripted in separately below instead
        -- of relying on the population system at all.
        SetFocusPosAndVel(c.x, c.y, c.z, 0.0, 0.0, 0.0)

        local deadline = GetGameTimer() + 1200
        while GetGameTimer() < deadline and inFeed and feedCameraId == cameraId do
            RequestCollisionAtCoord(c.x, c.y, c.z)
            DrawConnectingHud()
            Wait(0)
        end

        -- Exited (or tapped a different camera) while this was still
        -- streaming in — don't activate a cam nobody asked for anymore.
        if not inFeed or feedCameraId ~= cameraId then
            ClearFocus()
            return
        end

        SpawnFeedTraffic(c)

        -- Camera starts pointed the way it's mounted, at default zoom; all
        -- of that is relative from here, reset fresh every time a feed
        -- is opened.
        feedPan  = c.w or 0.0
        feedTilt = -6.0
        feedFov  = Config.FeedControl.defaultFov

        feedCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        SetCamCoord(feedCam, c.x, c.y, c.z + 0.35)
        SetCamRot(feedCam, feedTilt, 0.0, feedPan, 2)
        SetCamFov(feedCam, feedFov)
        SetCamActive(feedCam, true)
        -- Instant cut, no ease — a CCTV feed switches on, it doesn't fly the
        -- viewer's camera across the map to get there.
        RenderScriptCams(true, false, 0, true, true)
    end)
end

exports('StartFeed', StartFeed)
exports('StopFeed', ExitFeed)

RegisterCommand('flockexitfeed', ExitFeed, false)
RegisterKeyMapping('flockexitfeed', 'Exit Flock camera feed', 'keyboard', 'BACK')

CreateThread(function()
    while true do
        if not inFeed then
            Wait(500)
        else
            local ped = PlayerPedId()

            if GetEntityHealth(ped) < feedEnterHealth then
                ExitFeed()
            else
                DisableControlAction(0, 24, true)  -- attack
                DisableControlAction(0, 25, true)  -- aim
                DisableControlAction(0, 37, true)  -- weapon wheel
                DisableControlAction(0, 22, true)  -- jump

                -- feedCam only exists once the pre-roll stream-in thread
                -- finishes; until then that thread is drawing its own
                -- CONNECTING overlay, so there's nothing to do here.
                if feedCam then
                    local entry = cameras[feedCameraId]
                    if entry then
                        -- WASD (32-35, the normal movement controls). They
                        -- already do nothing while a feed is open — player
                        -- control is off — so repurposing them for look is a
                        -- clean swap, not a conflict. Pan wraps the full
                        -- 360°; Lua's % already handles the negative-heading
                        -- wrap correctly. Tilt is clamped so it can't flip
                        -- past vertical.
                        local dt = GetFrameTime()
                        local fc = Config.FeedControl

                        -- SetPlayerControl(false) suppresses plain
                        -- IsControlPressed for far more than the handful of
                        -- controls disabled above. Disable these ourselves
                        -- and read the disabled-input variant, which is
                        -- built to see through exactly that.
                        DisableControlAction(0, 32, true)  -- W, up
                        DisableControlAction(0, 33, true)  -- S, down
                        DisableControlAction(0, 34, true)  -- A, left
                        DisableControlAction(0, 35, true)  -- D, right

                        if IsDisabledControlPressed(0, 34) then  -- A
                            feedPan = (feedPan + fc.panSpeed * dt) % 360.0
                        end
                        if IsDisabledControlPressed(0, 35) then  -- D
                            feedPan = (feedPan - fc.panSpeed * dt) % 360.0
                        end
                        if IsDisabledControlPressed(0, 32) then  -- W, up
                            feedTilt = math.min(fc.maxPitch, feedTilt + fc.tiltSpeed * dt)
                        end
                        if IsDisabledControlPressed(0, 33) then  -- S, down
                            feedTilt = math.max(fc.minPitch, feedTilt - fc.tiltSpeed * dt)
                        end

                        -- Scroll wheel zoom. Each tick is a discrete pulse,
                        -- not a hold, so JustPressed (one step per tick)
                        -- rather than Pressed (would ramp with frame rate).
                        DisableControlAction(0, 14, true)  -- wheel up
                        DisableControlAction(0, 15, true)  -- wheel down

                        if IsDisabledControlJustPressed(0, 14) then  -- wheel up = zoom out
                            feedFov = math.min(fc.maxFov, feedFov + fc.zoomStep)
                        end
                        if IsDisabledControlJustPressed(0, 15) then  -- wheel down = zoom in
                            feedFov = math.max(fc.minFov, feedFov - fc.zoomStep)
                        end

                        SetCamRot(feedCam, feedTilt, 0.0, feedPan, 2)
                        SetCamFov(feedCam, feedFov)

                        DrawFeedHud(entry.cfg.label or feedCameraId, feedCameraId, cameraState[feedCameraId] ~= false)
                    else
                        ExitFeed()
                    end
                end
            end

            Wait(0)
        end
    end
end)

-- ─── Bootstrap ──────────────────────────────────────────────────────

CreateThread(function()
    Wait(1500)

    for _, cfg in ipairs(Config.Cameras) do
        SpawnCamera(cfg)
        cameraState[cfg.id] = true
    end

    hasAccess = lib.callback.await('distortionz_flock:server:hasAccess', false) or false
    RefreshBlips()

    DebugPrint(('Spawned %d camera(s). access=%s'):format(#Config.Cameras, tostring(hasAccess)))
end)

-- Job changes flip blip visibility without needing a reconnect.
CreateThread(function()
    while true do
        Wait(30000)

        local now = lib.callback.await('distortionz_flock:server:hasAccess', false) or false

        if now ~= hasAccess then
            hasAccess = now
            RefreshBlips()
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    -- A restart mid-feed must never leave the officer frozen with no radar.
    ExitFeed()

    for _, entry in pairs(cameras) do
        DeleteEntitySafe(entry.prop)
        DeleteEntitySafe(entry.pole)
        RemoveBlipSafe(entry.blip)
    end

    cameras = {}
end)
