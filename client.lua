-- =====================================================================
--  Distortionz Flock — client
--  Cosmetic and UI only. The client never detects, reads, or reports a
--  plate; it spawns props, draws blips, and asks the server questions.
-- =====================================================================

local cameras     = {}      -- [id] = { prop, pole, blip, cfg }
local cameraState = {}      -- [id] = online boolean
local sparkFx     = {}      -- [id] = looped ptfx handle, while tampered/offline
local hasAccess   = false

-- Forward-declared: SpawnCamera (defined below) wires an ox_target option
-- that calls this, but the actual tamper flow is defined further down,
-- after the counterplay section it belongs with.
local TryTamper

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

    -- Modern interaction path — the /flocktamper command (below) stays as
    -- a fallback for servers without ox_target running. Registered on
    -- BOTH the camera housing and the pole beneath it — the housing is a
    -- small target mounted well above head height, so a player's
    -- crosshair realistically lands on the much bigger pole instead.
    if GetResourceState('ox_target') == 'started' then
        local targets = pole and { prop, pole } or prop

        pcall(function()
            exports.ox_target:addLocalEntity(targets, {
                {
                    name     = 'flock_tamper_' .. cfg.id,
                    icon     = 'fa-solid fa-bolt',
                    label    = 'Tamper with camera',
                    distance = Config.Counterplay.useRadius,
                    onSelect = function() TryTamper(cfg.id) end,
                    canInteract = function()
                        return Config.Counterplay.enabled and cameraState[cfg.id] ~= false
                    end,
                },
            })
        end)
    end
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

    -- Per-camera style override, falling back to the global default.
    -- Doesn't bypass the enabled/policeOnly gate above — that's a policy
    -- decision, this is just look-and-feel.
    local bcfg = cfg.blip or Config.Blip
    local c = cfg.coords
    local blip = AddBlipForCoord(c.x, c.y, c.z)

    SetBlipSprite(blip, bcfg.sprite or 184)
    SetBlipColour(blip, cameraState[cfg.id] == false and 1 or (bcfg.color or 3))
    SetBlipScale(blip, bcfg.scale or 0.7)
    SetBlipAsShortRange(blip, bcfg.shortRange ~= false)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(bcfg.label or cfg.label or 'Flock Camera')
    EndTextCommandSetBlipName(blip)

    entry.blip = blip
end

local function RefreshBlips()
    for _, entry in pairs(cameras) do
        ApplyBlip(entry)
    end
end

-- ─── Tamper sparks ──────────────────────────────────────────────────
-- Purely cosmetic. 'core' is a base-game particle dict, always resident —
-- no streaming asset to fail to load.

local function StartSparks(cameraId, c)
    if sparkFx[cameraId] then return end

    RequestNamedPtfxAsset('core')
    local deadline = GetGameTimer() + 2000
    while not HasNamedPtfxAssetLoaded('core') and GetGameTimer() < deadline do
        Wait(0)
    end
    if not HasNamedPtfxAssetLoaded('core') then return end

    -- ent_brk_* effects are one-shot "just broke" reaction bursts — wrong
    -- category regardless of calling them via the Looped native. ent_amb_*
    -- is GTA's actual ambient/persistent effect naming convention.
    UseParticleFxAssetNextCall('core')
    sparkFx[cameraId] = StartParticleFxLoopedAtCoord(
        'ent_amb_elec_crackle', c.x, c.y, c.z + 0.7, 0.0, 0.0, 0.0, 3.0, false, false, false, false)
end

local function StopSparks(cameraId)
    local handle = sparkFx[cameraId]
    if not handle then return end

    if DoesParticleFxLoopedExist(handle) then
        StopParticleFxLooped(handle, false)
    end
    sparkFx[cameraId] = nil
end

RegisterNetEvent('distortionz_flock:client:cameraState', function(cameraId, online)
    cameraState[cameraId] = online

    local entry = cameras[cameraId]
    if entry and entry.blip and DoesBlipExist(entry.blip) then
        SetBlipColour(entry.blip, online and (Config.Blip.color or 3) or 1)
    end

    if online then
        StopSparks(cameraId)
    elseif entry then
        StartSparks(cameraId, entry.cfg.coords)
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

-- ─── Speed camera flash ─────────────────────────────────────────────
-- Purely cosmetic. Broadcast to everyone (server-side TriggerClientEvent
-- to -1) rather than just the offending driver — DrawLightWithRange only
-- renders for a client actually close enough to see it, so there's no
-- need to compute "who's nearby": anyone standing near the camera sees
-- an actual flash pop off it, plus the shutter sound.

RegisterNetEvent('distortionz_flock:client:cameraFlash', function(coords)
    if not coords then return end

    PlaySoundFrontend(-1, 'Camera_Shoot', 'Phone_SoundSet_Franklin', true)

    CreateThread(function()
        -- A real flash bulb isn't one flat pulse — three quick pops with
        -- brief dark gaps between reads far more like an actual camera
        -- strobing than a single steady light.
        local pulses = { 90, 60, 130 }

        for i = 1, #pulses do
            local deadline = GetGameTimer() + pulses[i]
            while GetGameTimer() < deadline do
                DrawLightWithRange(coords.x, coords.y, coords.z + 1.2, 255, 255, 255, 30.0, 25.0)
                Wait(0)
            end

            if i < #pulses then Wait(40) end
        end
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

--- Shared by both the /flocktamper command (proximity-based) and the
--- ox_target option on the camera prop itself (id already known, no
--- guessing needed) — one tamper flow, two ways to trigger it.
TryTamper = function(cameraId)
    if not Config.Counterplay.enabled then return end

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
end

-- Command stays as a fallback for servers without ox_target — the target
-- option below is the intended way to do this when it's running.
RegisterCommand('flocktamper', function()
    if not Config.Counterplay.enabled then return end

    local cameraId = NearestCamera()
    if not cameraId then
        Notify('No camera within reach.', 'error')
        return
    end

    TryTamper(cameraId)
end, false)

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

    for id in pairs(sparkFx) do
        StopSparks(id)
    end

    for _, entry in pairs(cameras) do
        DeleteEntitySafe(entry.prop)
        DeleteEntitySafe(entry.pole)
        RemoveBlipSafe(entry.blip)
    end

    cameras = {}
end)
