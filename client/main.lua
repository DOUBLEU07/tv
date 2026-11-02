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
    Private = {},       --@ [key "u:<id>"] = { key, x, y, z, h, w, ht, bucket, ownerName } จอส่วนตัวที่เราเป็นเจ้าของ/สมาชิก
    MyBucket = nil,     --@ มิติของเรา (ถามเซิร์ฟเฉพาะตอนมีจอส่วนตัวอยู่ใกล้)
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
    elseif kind == "c" then
        local c = Shared.Screens[key]
        return c and vector3(c.x, c.y, c.z)
    elseif kind == "u" then
        local p = TV.Private[key]
        return p and vector3(p.x, p.y, p.z)
    end
end

--@ จอส่วนตัว : เห็นเฉพาะตอนอยู่มิติเดียวกับจอ (จออื่น = true เสมอ)
function TV.Visible(key)
    if key:sub(1, 1) ~= "u" then return true end
    local p = TV.Private[key]
    return p ~= nil and TV.MyBucket ~= nil and p.bucket == TV.MyBucket
end

--@ จอแผ่น (ไม่มี entity) : จอใสที่แอดมินวาง / จอจาก Config.Screens / จอส่วนตัว -> { x, y, z, h, w, ht, fit }
function TV.FlatOf(key)
    local kind = key:sub(1, 1)
    if kind == "c" then return Shared.Screens[key] end
    if kind == "u" then return TV.Private[key] end
    if kind == "f" then
        local b = TV.Boards[key]
        if b then
            if not b.ht then b.ht = (b.w or Config.Board.Free.DefaultWidth) * 9 / 16 end
            return b
        end
    end
    return nil
end

--@ ระยะกด E / คลิก ของจอแผ่น (วัดจากกลางจอ)
function TV.FlatReach(key, flat)
    if key:sub(1, 1) == "c" then return flat.range end
    return Config.InteractDistance + math.max(flat.w or 2.0, flat.ht or 0.0) * 0.5
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
    TV.Private = s.private or {}
end

RegisterNetEvent(script .. ":cl:private", function(key, p)
    TV.Private[key] = p
    if not p then TV.Play[key] = nil end
end)

--@ คำเชิญเข้าจอส่วนตัว : กดปุ่มตอบ ไม่เปิด UI ไม่จับเมาส์ ; timeout = nil คือจอถูกเก็บ = ยกเลิกคำเชิญ
--@ ปุ่มผ่าน RegisterKeyMapping (เดิมอ่าน IsControlJustReleased : โดนสคริปต์อื่นปิด control = กด Y ไม่ติด
--@ และ "ปล่อยปุ่ม" ที่กดค้างมาตอนพิมพ์แชท/เปิด UI ถูกนับเป็นการตอบ = ปฏิเสธเองทั้งที่ไม่ได้กด)
local PendingInvite = nil

local function InviteKeyLabel(cmd, fallback)
    local b = GetControlInstructionalButton(0, joaat(cmd) | 0x80000000, true)
    if type(b) == "string" and b:sub(1, 2) == "t_" then return b:sub(3) end
    return fallback
end

local function ReplyInvite(accept)
    local inv = PendingInvite
    if not inv then return end
    if GetGameTimer() < inv.ready then return end
    if IsPauseMenuActive() or IsNuiFocused() or TV.UiOpen then return end
    PendingInvite = nil
    local res = lib.callback.await(script .. ":sv:pvInviteReply", false, inv.key, accept)
    if res and res.ok then
        TV.Notify(accept and "success" or "info", accept and "เข้าร่วมจอทีวีแล้ว" or "ปฏิเสธคำเชิญแล้ว")
    else
        TV.Notify("error", res and res.msg or "ไม่สำเร็จ")
    end
end

RegisterCommand("+bit_tv_accept", function() ReplyInvite(true) end, false)
RegisterCommand("-bit_tv_accept", function() end, false)
RegisterKeyMapping("+bit_tv_accept", "TV : ยอมรับคำเชิญเข้าจอส่วนตัว", "keyboard", Config.Private.Invite.AcceptKey or "Y")
RegisterCommand("+bit_tv_decline", function() ReplyInvite(false) end, false)
RegisterCommand("-bit_tv_decline", function() end, false)
RegisterKeyMapping("+bit_tv_decline", "TV : ปฏิเสธคำเชิญเข้าจอส่วนตัว", "keyboard", Config.Private.Invite.DeclineKey or "BACK")

RegisterNetEvent(script .. ":cl:pvInvite", function(key, ownerName, timeout)
    if not timeout then
        if PendingInvite and PendingInvite.key == key then
            PendingInvite = nil
            TV.Notify("info", "คำเชิญเข้าจอถูกยกเลิก (เจ้าของเก็บจอแล้ว)")
        end
        return
    end
    local I = Config.Private.Invite
    local now = GetGameTimer()
    local inv = { key = key, expires = now + timeout * 1000, ready = now + (I.Grace or 800) }
    PendingInvite = inv
    TV.Notify("info", ("%s เชิญคุณเข้าจอทีวีส่วนตัว : กด %s ยอมรับ / %s ปฏิเสธ"):format(ownerName,
        InviteKeyLabel("+bit_tv_accept", I.AcceptKey), InviteKeyLabel("+bit_tv_decline", I.DeclineKey)), timeout * 1000)
    SetTimeout(timeout * 1000, function()
        if PendingInvite == inv then
            PendingInvite = nil
            TV.Notify("error", "คำเชิญเข้าจอหมดเวลาแล้ว")
        end
    end)
end)

--@ มิติของเรา : ถามเซิร์ฟทุก 3 วิ เฉพาะตอนมีจอส่วนตัวอยู่ในระยะ (ไม่มีจอใกล้ = ไม่ถามเลย)
CreateThread(function()
    while true do
        local near = false
        if next(TV.Private) then
            local coords = GetEntityCoords(PlayerPedId())
            for _, p in pairs(TV.Private) do
                if #(coords - vector3(p.x, p.y, p.z)) <= Config.Render.Distance + 10.0 then near = true break end
            end
        end
        if near then
            local b = lib.callback.await(script .. ":sv:pvBucket", false)
            if b ~= nil then TV.MyBucket = b end
            Wait(3000)
        else
            Wait(2000)
        end
    end
end)

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

--@ โหมดเพลง : หน้า UI หลัก (web/music.js) บอกชื่อเพลง/ความยาว [rev] = { title, author, d, error }
TV.MusicInfo = {}
RegisterNUICallback("musicInfo", function(data, cb)
    if type(data) == "table" and type(data.rev) == "string" then
        local d = tonumber(data.d) or 0
        TV.MusicInfo[data.rev] = {
            title = type(data.title) == "string" and data.title:sub(1, 200) or "",
            author = type(data.author) == "string" and data.author:sub(1, 120) or "",
            d = d,
            error = data.error == true,
        }
        if d > 0 then TV.Duration[data.rev] = d end
    end
    cb(true)
end)

--@ วินาทีของคลิปตอนนี้ : หยุดอยู่ = ตำแหน่งที่หยุด / รอโฆษณา = วินาทีเริ่ม
function TV.Elapsed(st, now)
    if st.gate then return st.media.s or 0 end
    if st.paused then return st.pausePos or 0 end
    return math.max(0.0, now - st.startAt)
end

local function RemoteData(key, info)
    local st = info.play
    local media = st and st.media
    local pv = info.private
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
            canSeek = Shared.CanSeek(media) and not st.gate,
            canPause = pv ~= nil and Shared.CanSeek(media) and not st.gate,
            paused = st.paused == true,
            gate = st.gate and { r = st.gate.r, n = st.gate.n, left = math.max(0, math.ceil(st.gate.endsAt - info.now)) } or nil,
            waiting = info.waiting,
            elapsed = TV.Elapsed(st, info.now),
            duration = TV.Duration[key .. "|" .. tostring(st.id)],
        } or nil,
        vol = st and st.vol or info.defaultVolume,
        personal = TV.Personal,
        private = pv and {
            owner = pv.owner,
            memberCtl = pv.memberCtl,
            max = pv.max,
            members = pv.members,
            invites = pv.invites or {},
            addDistance = pv.addDistance,
        } or nil,
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

--@ จอส่วนตัว : สถานะเปลี่ยน (คนพ้นโฆษณา / เริ่ม / หยุด) ระหว่างเปิดรีโมทอยู่ = อัปเดตรีโมท
RegisterNetEvent(script .. ":cl:play", function(key)
    if current and current.mode == "remote" and current.key == key and key:sub(1, 1) == "u" then RefreshRemote() end
end)

RegisterNetEvent(script .. ":cl:private", function(key, p)
    if not p and current and current.key == key and not current.removing then
        CloseUI()
        TV.Notify("info", "จอนี้ถูกเก็บแล้ว / คุณไม่ได้เป็นสมาชิกแล้ว")
    end
end)

--@ จอใน DUI : เนื้อคลิปเริ่มแล้ว (พ้นโฆษณา) -> บอกเซิร์ฟ ครั้งเดียวต่อคลิป
local adSent = {}
RegisterNUICallback("adReady", function(data, cb)
    cb(true)
    if type(data) ~= "table" or type(data.rev) ~= "string" or adSent[data.rev] then return end
    local key, id = data.rev:match("^(u:%d+)|(%d+)$")
    local st = key and TV.Play[key]
    if not st or not st.gate or tostring(st.id) ~= id then return end
    adSent[data.rev] = true
    TriggerServerEvent(script .. ":sv:adReady", key, tonumber(id))
end)

local OpenSubmit

--@ เปิด UI ของจอ (กด E / Alt+คลิก ใช้ร่วมกัน)
function TV.OpenScreen(key)
    if TV.UiOpen or TV.Busy then return end
    if TV.Boards[key] then OpenSubmit(key) else OpenRemote(key) end
end

function OpenSubmit(key)
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
    for key, c in pairs(Shared.Screens) do
        if c.mode == "tv" then
            local d = #(coords - vector3(c.x, c.y, c.z))
            if d <= range then
                local st = TV.Play[key]
                list[#list + 1] = {
                    key = key,
                    model = "จอแผ่น " .. c.id,
                    config = true,
                    dist = math.floor(d * 10 + 0.5) / 10,
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
    elseif data.act == "pause" or data.act == "resume" then
        res = lib.callback.await(script .. ":sv:tvPause", false, key, meta, data.act == "pause")
        if res and not res.ok then TV.Notify("error", res.msg or "ไม่สำเร็จ") end
    elseif data.act == "gateStart" then
        res = lib.callback.await(script .. ":sv:tvGateStart", false, key, meta)
        if res and not res.ok then TV.Notify("error", res.msg or "ไม่สำเร็จ") end
    elseif data.act == "member" then
        res = lib.callback.await(script .. ":sv:pvMember", false, key, data.op, data.value)
        if res and not res.ok then TV.Notify("error", res.msg or "ไม่สำเร็จ")
        elseif res and data.op == "add" then TV.Notify("success", "ส่งคำเชิญแล้ว รอเขากดยอมรับ") end
    elseif data.act == "leave" and key:sub(1, 1) == "u" then
        current.removing = true
        res = lib.callback.await(script .. ":sv:pvLeave", false, key)
        if res and res.ok then
            TV.Notify("success", "ออกจากจอแล้ว")
            CloseUI()
            return cb(res)
        end
        current.removing = nil
        TV.Notify("error", res and res.msg or "ออกไม่สำเร็จ")
    elseif data.act == "remove" and key:sub(1, 1) == "u" then
        current.removing = true
        res = lib.callback.await(script .. ":sv:pvRemove", false, key)
        if res and res.ok then
            TV.Notify("success", "เก็บจอแล้ว")
            CloseUI()
            return cb(res)
        end
        TV.Notify("error", res and res.msg or "เก็บไม่สำเร็จ")
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
    --@ จอแผ่น : จอใส + จอจาก Config.Screens (กด E ได้ในระยะ InteractDistance + ครึ่งจอ)
    local function Flat(fkey, f)
        local fd = #(coords - vector3(f.x, f.y, f.z))
        local reach = Config.InteractDistance + math.max(f.w or 2.0, f.ht or 0.0) * 0.5
        if fd <= reach and (not target or fd < target.dist) then
            target = { key = fkey, coords = vector3(f.x, f.y, f.z), dist = fd, reach = reach }
        end
    end
    for bkey, b in pairs(TV.Boards) do
        if b.kind == "free" then Flat(bkey, TV.FlatOf(bkey)) end
    end
    for ckey, c in pairs(Shared.Screens) do Flat(ckey, c) end
    for pkey, p in pairs(TV.Private) do
        if TV.Visible(pkey) then Flat(pkey, p) end
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
                    exports["bit_text3d"]:TogglePressKey({ key = "E", text = label, coords = target.coords, dis = (target.reach or Config.InteractDistance) + 1.0, slot = SLOT })
                end)
            end
            if IsControlJustReleased(0, Config.Key) then
                local key = target.key
                target = nil
                TV.OpenScreen(key)
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
