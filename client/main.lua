local script = GetCurrentResourceName()
local SLOT = "bit_tv"
local KVP_VOL = script .. ":vol"

--@ state กลาง ใช้ร่วมกับ render.lua / place.lua
TV = {
    Play = {},          --@ [key] = { media, startAt, vol, by }
    Props = {},         --@ [id] = { id, model, x, y, z, h, owner, ownerName }
    PropEnt = {},       --@ [id] = entity (prop ฝั่ง client)
    PropByEnt = {},     --@ [entity] = id
    Boards = {},        --@ [key] = { key, group, kind, x, y, z, h, w }
    Queue = {},         --@ [group] = { { id, post, startAt }, ... }
    Offset = 0.0,       --@ เวลาเซิร์ฟ - เวลาเครื่องเรา (วินาที)
    Personal = Config.Audio.DefaultPersonal,
    UiOpen = false,
    Busy = false,       --@ อยู่ในโหมดวาง/จูน
}

function TV.Notify(kind, text, time)
    pcall(function()
        exports["bit_itemnotify"]:AddNotify({ type = kind, text = text, time = time or 4000 })
    end)
end

function TV.ServerNow()
    return GetGameTimer() / 1000.0 + TV.Offset
end

local function SetOffset(serverNow)
    if serverNow then TV.Offset = serverNow - GetGameTimer() / 1000.0 end
end

do
    local v = GetResourceKvpInt(KVP_VOL)
    local raw = GetResourceKvpString(KVP_VOL .. ":set")
    if raw == "1" then TV.Personal = v end
end

local function SetPersonal(v)
    TV.Personal = math.floor(math.max(0, math.min(100, v)))
    SetResourceKvpInt(KVP_VOL, TV.Personal)
    SetResourceKvp(KVP_VOL .. ":set", "1")
end

--@ ================================================================================================
--@ ตำแหน่งจอจาก key
--@ ================================================================================================
function TV.ParseMapKey(key)
    local h, x, y, z = key:match("^m:(%d+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+)$")
    if not h then return nil end
    return tonumber(h), vector3(tonumber(x), tonumber(y), tonumber(z))
end

function TV.KeyPos(key)
    local kind = key:sub(1, 1)
    if kind == "m" then
        local _, pos = TV.ParseMapKey(key)
        return pos
    elseif kind == "p" then
        local p = TV.Props[tonumber(key:sub(3))]
        return p and vector3(p.x, p.y, p.z)
    elseif kind == "f" then
        local b = TV.Boards[key]
        return b and vector3(b.x, b.y, b.z)
    end
end

--@ entity ของจอ (ทีวีในแมพ / prop ที่วาง) ; จอใส = nil
local EntCache = {}
function TV.KeyEntity(key)
    local kind = key:sub(1, 1)
    if kind == "p" then
        local e = TV.PropEnt[tonumber(key:sub(3))]
        return e and DoesEntityExist(e) and e or nil
    elseif kind == "m" then
        local e = EntCache[key]
        if e and DoesEntityExist(e) then return e end
        local hash, pos = TV.ParseMapKey(key)
        if not hash then return nil end
        local model = Shared.Models[hash] and Shared.Models[hash].model
        if not model then return nil end
        e = GetClosestObjectOfType(pos.x, pos.y, pos.z, 0.6, GetHashKey(model), false, false, false)
        if e ~= 0 then EntCache[key] = e; return e end
    end
    return nil
end

--@ meta ให้เซิร์ฟสร้าง key ทีวีในแมพเทียบ
function TV.KeyMeta(key)
    local hash, pos = TV.ParseMapKey(key)
    if not hash then return nil end
    return { model = hash, x = pos.x, y = pos.y, z = pos.z }
end

--@ หา TV ใกล้ตัว -> key, entity
function TV.FindNearestTv(maxDist)
    local coords = GetEntityCoords(PlayerPedId())
    local best, bestD, bestKey
    for hash, m in pairs(Shared.Models) do
        local e = GetClosestObjectOfType(coords.x, coords.y, coords.z, maxDist, GetHashKey(m.model), false, false, false)
        if e ~= 0 then
            local d = #(coords - GetEntityCoords(e))
            if not bestD or d < bestD then best, bestD = e, d end
        end
    end
    if not best then return nil end
    local pid = TV.PropByEnt[best]
    if pid then
        bestKey = "p:" .. pid
    else
        local p = GetEntityCoords(best)
        bestKey = Shared.MapKey(GetEntityModel(best), p.x, p.y, p.z)
    end
    return bestKey, best, bestD
end

--@ ================================================================================================
--@ sync
--@ ================================================================================================
local function FullSync()
    local s = lib.callback.await(script .. ":sv:sync", false)
    if not s then return end
    SetOffset(s.now)
    TV.Play = s.play or {}
    TV.Boards = s.boards or {}
    TV.Queue = s.queue or {}
    for id in pairs(TV.Props) do TV.RemovePropEntity(id) end
    TV.Props = {}
    for id, p in pairs(s.props or {}) do TV.Props[tonumber(id)] = p end
    TV.Calib = {}
    for k, c in pairs(s.calib or {}) do TV.SetCalib(k, c) end
end

RegisterNetEvent(script .. ":cl:calib", function(k, c)
    TV.SetCalib(k, c)
end)

RegisterNetEvent(script .. ":cl:play", function(key, state, serverNow)
    SetOffset(serverNow)
    TV.Play[key] = state
end)

RegisterNetEvent(script .. ":cl:volume", function(key, vol)
    if TV.Play[key] then TV.Play[key].vol = vol end
end)

RegisterNetEvent(script .. ":cl:prop", function(id, p)
    id = tonumber(id)
    if not p then
        TV.RemovePropEntity(id)
        TV.Props[id] = nil
        return
    end
    TV.Props[id] = p
end)

RegisterNetEvent(script .. ":cl:board", function(key, b)
    TV.Boards[key] = b
end)

RegisterNetEvent(script .. ":cl:post", function(group, entry, serverNow)
    SetOffset(serverNow)
    local q = TV.Queue[group] or {}
    q[#q + 1] = entry
    table.sort(q, function(a, b) return a.startAt < b.startAt end)
    TV.Queue[group] = q
end)

RegisterNetEvent(script .. ":cl:queue", function(group, list, serverNow)
    SetOffset(serverNow)
    TV.Queue[group] = list or {}
end)

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    Wait(1000)
    FullSync()
end)

--@ ================================================================================================
--@ NUI
--@ ================================================================================================
local current = nil     --@ { key, meta, mode } จอที่เปิด UI อยู่

local function OpenUI(mode, data)
    TV.UiOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = "open", mode = mode, data = data })
end

local function CloseUI()
    TV.UiOpen = false
    current = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "close" })
end
TV.CloseUI = CloseUI

function TV.Hint(lines)
    SendNUIMessage({ action = "hint", lines = lines })
end

RegisterNUICallback("close", function(_, cb)
    CloseUI()
    cb(true)
end)

--@ ความยาวคลิป (วินาที) ที่จอในเครื่องเรารายงานมา [rev] = วินาที ; rev = key|playId
TV.Duration = {}
RegisterNUICallback("duration", function(data, cb)
    if type(data) == "table" and type(data.rev) == "string" and tonumber(data.d) then
        TV.Duration[data.rev] = tonumber(data.d)
    end
    cb(true)
end)

local function RemoteData(key, info)
    local st = info.play
    local media = st and st.media
    return {
        key = key,
        canControl = info.canControl,
        canRemove = info.canRemove,
        ownerName = info.ownerName,
        playing = media and {
            url = media.url,
            provider = Shared.ProviderLabel[media.p] or media.p,
            music = media.ao == true,
            audio = Shared.AudioControl[media.p],
            by = st.by,
            canSeek = Shared.CanSeek(media),
            elapsed = math.max(0, info.now - st.startAt),
            duration = TV.Duration[key .. "|" .. tostring(st.id)],
        } or nil,
        vol = st and st.vol or info.defaultVolume,
        personal = TV.Personal,
    }
end

local function OpenRemote(key)
    local meta = TV.KeyMeta(key)
    local info = lib.callback.await(script .. ":sv:tvInfo", false, key, meta)
    if not info then return TV.Notify("error", "เปิดทีวีนี้ไม่ได้") end
    if info.board then return end
    current = { key = key, meta = meta, mode = "remote", canControl = info.canControl }
    OpenUI("remote", RemoteData(key, info))
end

local function RefreshRemote()
    if not current or current.mode ~= "remote" then return end
    local info = lib.callback.await(script .. ":sv:tvInfo", false, current.key, current.meta)
    if info then SendNUIMessage({ action = "update", data = RemoteData(current.key, info) }) end
end

local function OpenSubmit(key)
    local meta = TV.KeyMeta(key)
    local info = lib.callback.await(script .. ":sv:boardInfo", false, key, meta)
    if not info then return TV.Notify("error", "เปิดจอนี้ไม่ได้") end
    current = { key = key, meta = meta, mode = "submit" }
    info.duration = Config.Board.Duration
    OpenUI("submit", info)
end

--@ ทีวีรอบตัวสำหรับแท็บแอดมิน (วน object pool เฉพาะตอนแอดมินเปิดแผง)
local function NearbyTvs()
    local coords = GetEntityCoords(PlayerPedId())
    local range = Config.TV.AdminRange
    local list = {}
    for _, e in ipairs(GetGamePool("CObject")) do
        local cfg = Shared.Models[Shared.ModelHash(GetEntityModel(e))]
        if cfg then
            local p = GetEntityCoords(e)
            local d = #(coords - p)
            if d <= range then
                local pid = TV.PropByEnt[e]
                local key = pid and ("p:" .. pid) or Shared.MapKey(GetEntityModel(e), p.x, p.y, p.z)
                local st = TV.Play[key]
                local b = TV.Boards[key]
                list[#list + 1] = {
                    key = key,
                    model = cfg.model,
                    placed = pid ~= nil,
                    dist = math.floor(d * 10 + 0.5) / 10,
                    board = b and b.group or nil,
                    provider = st and st.media and (Shared.ProviderLabel[st.media.p] or st.media.p) or nil,
                    url = st and st.media and st.media.url or nil,
                    by = st and st.by or nil,
                }
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

function TV.OpenAdmin(tab)
    local res = lib.callback.await(script .. ":sv:admin", false, "list", {})
    if not res or not res.ok then return TV.Notify("error", res and res.msg or "เฉพาะแอดมิน") end
    current = { mode = "admin" }
    res.tab = tab
    res.duration = Config.Board.Duration
    res.defaultWidth = Config.Board.Free.DefaultWidth
    res.nearby = NearbyTvs()
    res.adminRange = Config.TV.AdminRange
    OpenUI("admin", res)
end

RegisterNUICallback("remote", function(data, cb)
    if not current or current.mode ~= "remote" then return cb({ ok = false }) end
    local key, meta = current.key, current.meta
    local res = { ok = true }
    if data.act == "touch" then
        local mirror = current.canControl == true
        CloseUI()
        cb({ ok = true })
        TV.Touch(key, mirror)
        return
    elseif data.act == "play" then
        res = lib.callback.await(script .. ":sv:tvPlay", false, key, meta, data.url, data.vol, data.music == true)
        if res and not res.ok then TV.Notify("error", res.msg or "เปิดไม่สำเร็จ") end
    elseif data.act == "stop" then
        res = lib.callback.await(script .. ":sv:tvStop", false, key, meta)
        if res and not res.ok then TV.Notify("error", res.msg or "ปิดไม่สำเร็จ") end
    elseif data.act == "seek" then
        res = lib.callback.await(script .. ":sv:tvSeek", false, key, meta, tonumber(data.pos))
        if res and not res.ok then TV.Notify("error", res.msg or "กรอไม่สำเร็จ") end
    elseif data.act == "volume" then
        res = lib.callback.await(script .. ":sv:tvVolume", false, key, meta, data.vol)
    elseif data.act == "personal" then
        SetPersonal(tonumber(data.vol) or TV.Personal)
    elseif data.act == "remove" then
        res = lib.callback.await(script .. ":sv:propRemove", false, tonumber(key:sub(3)))
        if res and res.ok then
            TV.Notify("success", "เก็บทีวีแล้ว")
            CloseUI()
            return cb(res)
        end
        TV.Notify("error", res and res.msg or "เก็บไม่สำเร็จ")
    end
    RefreshRemote()
    cb(res or { ok = false })
end)

RegisterNUICallback("submit", function(data, cb)
    if not current or current.mode ~= "submit" then return cb({ ok = false }) end
    local res = lib.callback.await(script .. ":sv:boardSubmit", false, current.key, current.meta, data)
    if res and res.ok then
        TV.Notify("success", res.msg)
        CloseUI()
    else
        TV.Notify("error", res and res.msg or "ส่งไม่สำเร็จ")
    end
    cb(res or { ok = false })
end)

RegisterNUICallback("admin", function(data, cb)
    if not current or current.mode ~= "admin" then return cb({ ok = false }) end
    local act, payload = data.act, data.payload or {}

    if act == "createFree" then
        CloseUI()
        cb({ ok = true })
        TV.PlaceBoard(payload.group, tonumber(payload.w) or Config.Board.Free.DefaultWidth)
        return
    elseif act == "attachTv" then
        local key = TV.FindNearestTv(5.0)
        if not key then
            TV.Notify("error", "ไม่พบทีวีในระยะ 5 เมตร")
            return cb({ ok = false })
        end
        payload.key = key
        payload.meta = TV.KeyMeta(key)
    elseif act == "nearby" then
        return cb({ ok = true, nearby = NearbyTvs() })
    elseif act == "control" then
        CloseUI()
        cb({ ok = true })
        OpenRemote(payload.key)
        return
    elseif act == "goto" then
        local b = TV.Boards[payload.key]
        if b then SetNewWaypoint(b.x, b.y) end
        TV.Notify("info", "ปักหมุดจอแล้ว")
        return cb({ ok = true })
    end

    local res = lib.callback.await(script .. ":sv:admin", false, act, payload)
    if res and not res.ok then TV.Notify("error", res.msg or "ไม่สำเร็จ") end
    cb(res or { ok = false })
end)

RegisterNUICallback("place", function(data, cb)
    CloseUI()
    cb(true)
    TV.PlaceProp(data.model)
end)

--@ ================================================================================================
--@ กด E ที่ทีวี / จอวาร์ป
--@ ================================================================================================
local function FindTarget()
    local coords = GetEntityCoords(PlayerPedId())
    local key, ent, d = TV.FindNearestTv(Config.TV.ScanDistance)
    local target
    if key and d <= Config.InteractDistance + 0.5 then
        target = { key = key, coords = GetEntityCoords(ent), dist = d }
    end
    --@ จอใส
    for bkey, b in pairs(TV.Boards) do
        if b.kind == "free" then
            local bd = #(coords - vector3(b.x, b.y, b.z))
            if bd <= Config.InteractDistance + (b.w or 2.0) * 0.5 and (not target or bd < target.dist) then
                target = { key = bkey, coords = vector3(b.x, b.y, b.z), dist = bd }
            end
        end
    end
    return target
end

CreateThread(function()
    local shown = nil
    local target = nil
    local lastScan = 0
    while true do
        local sleep = 500
        local now = GetGameTimer()
        if TV.UiOpen or TV.Busy or IsPedInAnyVehicle(PlayerPedId(), false) then
            target = nil
        elseif now - lastScan >= 400 then
            lastScan = now
            target = FindTarget()
        end

        if target then
            sleep = 0
            local isBoard = TV.Boards[target.key] ~= nil
            local label = isBoard and "ลงวาร์ป" or "ทีวี"
            if shown ~= target.key .. label then
                shown = target.key .. label
                pcall(function()
                    exports["bit_text3d"]:TogglePressKey({ key = "E", text = label, coords = target.coords, dis = Config.InteractDistance + 1.0, slot = SLOT })
                end)
            end
            if IsControlJustReleased(0, Config.Key) then
                local key = target.key
                target = nil
                if isBoard then OpenSubmit(key) else OpenRemote(key) end
            end
        elseif shown then
            shown = nil
            pcall(function() exports["bit_text3d"]:RemovePressKey(SLOT) end)
        end
        Wait(sleep)
    end
end)

--@ ================================================================================================
--@ คำสั่ง
--@ ================================================================================================
RegisterCommand(Config.Command.Volume, function(_, args)
    local v = tonumber(args[1])
    if not v then return TV.Notify("info", ("เสียงทีวีของคุณ %d%% (/%s 0-100)"):format(TV.Personal, Config.Command.Volume)) end
    SetPersonal(v)
    TV.Notify("success", TV.Personal == 0 and "ปิดเสียงทีวีทั้งหมดแล้ว" or ("เสียงทีวีของคุณ %d%%"):format(TV.Personal))
end, false)

RegisterCommand(Config.Board.AdminCommand, function()
    if TV.UiOpen or TV.Busy then return end
    TV.OpenAdmin()
end, false)

if Config.TV.Place.Enable then
    RegisterCommand(Config.TV.Place.Command, function()
        if TV.UiOpen or TV.Busy then return end
        current = { mode = "place" }
        OpenUI("place", { models = Config.TV.Place.Models })
    end, false)
end

AddEventHandler("onResourceStop", function(res)
    if res ~= script then return end
    if TV.UiOpen then SetNuiFocus(false, false) end
    pcall(function() exports["bit_text3d"]:RemovePressKey(SLOT) end)
end)
