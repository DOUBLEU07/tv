local script = GetCurrentResourceName()

--@ ================================================================================================
--@ prop ทีวีที่วางเอง : สร้างฝั่ง client เฉพาะตอนอยู่ใกล้ (ไม่ใช่ entity ใน network)
--@ ================================================================================================
local function LoadModel(model)
    if not IsModelInCdimage(model) then return false end
    RequestModel(model)
    local t = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < t do Wait(0) end
    return HasModelLoaded(model)
end

function TV.RemovePropEntity(id)
    local e = TV.PropEnt[id]
    if e then
        TV.PropByEnt[e] = nil
        if DoesEntityExist(e) then DeleteEntity(e) end
    end
    TV.PropEnt[id] = nil
end

CreateThread(function()
    while true do
        local coords = GetEntityCoords(PlayerPedId())
        local range = Config.TV.Place.SpawnDistance
        for id, p in pairs(TV.Props) do
            local d = #(coords - vector3(p.x, p.y, p.z))
            local e = TV.PropEnt[id]
            if d <= range and not (e and DoesEntityExist(e)) then
                if LoadModel(p.model) then
                    e = CreateObjectNoOffset(p.model, p.x, p.y, p.z, false, false, false)
                    SetEntityHeading(e, p.h)
                    FreezeEntityPosition(e, true)
                    SetModelAsNoLongerNeeded(p.model)
                    TV.PropEnt[id] = e
                    TV.PropByEnt[e] = id
                end
            elseif d > range + 10.0 and e then
                TV.RemovePropEntity(id)
            end
        end
        Wait(1500)
    end
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= script then return end
    for id in pairs(TV.PropEnt) do TV.RemovePropEntity(id) end
end)

--@ ================================================================================================
--@ ตัวช่วยโหมดวาง
--@ ================================================================================================
local function CamDir()
    local rot = GetGameplayCamRot(2)
    local x, z = math.rad(rot.x), math.rad(rot.z)
    local c = math.abs(math.cos(x))
    return vector3(-math.sin(z) * c, math.cos(z) * c, math.sin(x))
end

local function Raycast(dist, ignore)
    local from = GetGameplayCamCoord()
    local to = from + CamDir() * dist
    local h = StartShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1 + 16, ignore or PlayerPedId(), 7)
    local status, hit, pos
    repeat
        status, hit, pos = GetShapeTestResult(h)
        if status == 1 then Wait(0) end
    until status ~= 1
    if hit == 1 then return pos end
    return to
end

local BLOCK = { 14, 15, 16, 17, 24, 25, 37, 44, 45, 140, 141, 142, 172, 173, 174, 175, 191, 194, 199, 200, 202, 241, 242, 257, 263, 264 }
local function BlockControls()
    for i = 1, #BLOCK do DisableControlAction(0, BLOCK[i], true) end
end

local function Pressed(c) return IsDisabledControlJustPressed(0, c) end
local function Held(c) return IsDisabledControlPressed(0, c) end
local function Shift() return IsControlPressed(0, 21) end

local function Outline(a, b, c, d, r, g, bl)
    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, r, g, bl, 255)
    DrawLine(b.x, b.y, b.z, c.x, c.y, c.z, r, g, bl, 255)
    DrawLine(c.x, c.y, c.z, d.x, d.y, d.z, r, g, bl, 255)
    DrawLine(d.x, d.y, d.z, a.x, a.y, a.z, r, g, bl, 255)
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, r, g, bl, 70)
    DrawPoly(a.x, a.y, a.z, c.x, c.y, c.z, d.x, d.y, d.z, r, g, bl, 70)
    DrawPoly(a.x, a.y, a.z, c.x, c.y, c.z, b.x, b.y, b.z, r, g, bl, 70)
    DrawPoly(a.x, a.y, a.z, d.x, d.y, d.z, c.x, c.y, c.z, r, g, bl, 70)
end

local function Begin()
    TV.Busy = true
end

local function Finish()
    TV.Busy = false
    TV.Hint(nil)
end

--@ ================================================================================================
--@ วางทีวี
--@ ================================================================================================
function TV.PlaceProp(modelName)
    local ok = false
    for _, m in ipairs(Config.TV.Place.Models) do
        if m.model == modelName then ok = true end
    end
    if not ok or TV.Busy then return end
    local model = GetHashKey(modelName)
    if not LoadModel(model) then return TV.Notify("error", "โหลดโมเดลไม่ได้") end

    Begin()
    local ped = PlayerPedId()
    local pc = GetEntityCoords(ped)
    local preview = CreateObjectNoOffset(model, pc.x, pc.y, pc.z, false, false, false)
    SetEntityAlpha(preview, 180, false)
    SetEntityCollision(preview, false, false)
    FreezeEntityPosition(preview, true)
    local heading = (GetEntityHeading(ped) + 180.0) % 360.0
    local zOff = 0.0
    local maxD = Config.TV.Place.MaxDistance

    TV.Hint({
        "<b>วางทีวี</b>",
        "เมาส์ = เล็งตำแหน่ง",
        "ลูกกลิ้ง / ← → = หมุน (Shift = ละเอียด)",
        "↑ ↓ = ยก/ลด",
        "Enter = วาง   Backspace = ยกเลิก",
    })

    local result = nil
    while result == nil do
        BlockControls()
        local step = Shift() and 1.0 or 5.0
        if Pressed(14) or Held(175) then heading = heading - (Held(175) and step * 0.4 or step) end
        if Pressed(15) or Held(174) then heading = heading + (Held(174) and step * 0.4 or step) end
        if Held(172) then zOff = zOff + (Shift() and 0.002 or 0.01) end
        if Held(173) then zOff = zOff - (Shift() and 0.002 or 0.01) end

        local pos = Raycast(maxD + 3.0, preview) + vector3(0.0, 0.0, zOff)
        SetEntityCoordsNoOffset(preview, pos.x, pos.y, pos.z, false, false, false)
        SetEntityHeading(preview, heading % 360.0)
        local far = #(GetEntityCoords(ped) - pos) > maxD
        SetEntityAlpha(preview, far and 80 or 180, false)

        if Pressed(191) then
            if far then
                TV.Notify("error", "ไกลตัวเกินไป")
            else
                result = { x = pos.x, y = pos.y, z = pos.z, h = heading % 360.0 }
            end
        elseif Pressed(194) or Pressed(202) then
            result = false
        end
        Wait(0)
    end

    DeleteEntity(preview)
    SetModelAsNoLongerNeeded(model)
    Finish()
    if not result then return end
    local res = lib.callback.await(script .. ":sv:propPlace", false, model, result.x, result.y, result.z, result.h)
    if res and res.ok then TV.Notify("success", "วางทีวีแล้ว เดินไปกด E เพื่อเปิดลิงก์") else TV.Notify("error", res and res.msg or "วางไม่สำเร็จ") end
end

--@ ================================================================================================
--@ เล็งวางจอแผ่น : ใช้ทั้งวางจอใส และ /tvpos (หาพิกัดใส่ Config.Screens)
--@ -> { x, y, z, h, w, ht } / false = ยกเลิก
--@ ================================================================================================
--@ opt.lock = สูงตามกว้าง 16:9 เสมอ / opt.maxDist = ห้ามวางไกลตัวเกินนี้ (กรอบแดง กด Enter ไม่ได้)
--@ opt.border = ขอบกรอบ (ส่วนของความกว้าง) : ยกจอขึ้นเท่าขอบ ให้ขอบล่างวางบนพื้นพอดี ไม่จมพื้น
local function AimPanel(title, w, ht, lim, opt)
    opt = opt or {}
    local ped = PlayerPedId()
    local heading = (GetEntityHeading(ped) + 180.0) % 360.0
    local zOff = 0.0

    TV.Hint({
        title,
        "เมาส์ = เล็งตำแหน่ง   ลูกกลิ้ง = หมุน",
        opt.lock and "↑ ↓ = ยก/ลด   ← → = ขนาด" or "↑ ↓ = ยก/ลด   ← → = กว้าง   PgUp / PgDn = สูง",
        opt.lock and "Shift = ละเอียด" or "Shift = ละเอียด   R = กลับเป็น 16:9",
        "Enter = ตกลง   Backspace = ยกเลิก",
    })

    local result = nil
    while result == nil do
        BlockControls()
        DisableControlAction(0, 10, true)
        DisableControlAction(0, 11, true)
        DisableControlAction(0, 45, true)
        local fine = Shift()
        local step = fine and 1.0 or 5.0
        local d = fine and 0.005 or 0.03
        if Pressed(14) then heading = heading - step end
        if Pressed(15) then heading = heading + step end
        if Held(172) then zOff = zOff + d end
        if Held(173) then zOff = zOff - d end
        if Held(175) then w = math.min(lim.maxW, w + d) end
        if Held(174) then w = math.max(lim.minW, w - d) end
        if Held(10) then ht = math.min(lim.maxH, ht + d) end
        if Held(11) then ht = math.max(lim.minH, ht - d) end
        if Pressed(45) then ht = math.max(lim.minH, math.min(lim.maxH, w * 9 / 16)) end
        if opt.lock then ht = w * 9 / 16 end

        local hit = Raycast(25.0)
        local c = hit + vector3(0.0, 0.0, ht * 0.5 + zOff + w * (opt.border or 0.0))
        local fr = TV.HeadingFrame(c.x, c.y, c.z, heading)
        local a, b, cc, dd = TV.Corners(fr, 0.0, 0.0, 0.0, w, ht, 1)
        local far = opt.maxDist and #(GetEntityCoords(ped) - c) > opt.maxDist
        if far then Outline(a, b, cc, dd, 255, 80, 90) else Outline(a, b, cc, dd, 0, 182, 176) end
        --@ บอกขนาดตรงกลางจอ
        SetDrawOrigin(c.x, c.y, c.z, 0)
        SetTextScale(0.0, 0.32)
        SetTextFont(4)
        SetTextCentre(true)
        SetTextOutline()
        BeginTextCommandDisplayText("STRING")
        AddTextComponentSubstringPlayerName(("%.2f x %.2f m"):format(w, ht))
        EndTextCommandDisplayText(0.0, 0.0)
        ClearDrawOrigin()

        if Pressed(191) then
            if far then
                TV.Notify("error", "ไกลตัวเกินไป")
            else
                result = { x = c.x, y = c.y, z = c.z, h = heading % 360.0, w = w, ht = ht }
            end
        elseif Pressed(194) or Pressed(202) then
            result = false
        end
        Wait(0)
    end
    return result
end

--@ ================================================================================================
--@ วางจอส่วนตัว (กดใช้ไอเทม Config.Private.Item)
--@ ================================================================================================
function TV.PlacePrivate()
    if TV.Busy or TV.UiOpen then return end
    local P = Config.Private
    local w = math.max(P.MinWidth, math.min(P.MaxWidth, P.Width))
    local lim = { minW = P.MinWidth, maxW = P.MaxWidth, minH = P.MinWidth * 9 / 16, maxH = P.MaxWidth * 9 / 16 }
    Begin()
    local r = AimPanel("<b>วางจอส่วนตัว</b> (เห็นเฉพาะคุณ + สมาชิก)", w, w * 9 / 16, lim, { lock = true, maxDist = P.MaxDistance, border = P.Frame and P.Frame.Enable and P.Frame.Border or 0.0 })
    Finish()
    if not r then return end
    local res = lib.callback.await(script .. ":sv:pvPlace", false, r.x, r.y, r.z, r.h, r.w)
    if res and res.ok then
        TV.Notify("success", "วางจอแล้ว กด E ที่จอเพื่อเปิดลิงก์ / เพิ่มสมาชิก (กดใช้ไอเทมอีกครั้ง = เก็บ)", 6000)
    else
        TV.Notify("error", res and res.msg or "วางไม่สำเร็จ")
    end
end

RegisterNetEvent(script .. ":cl:pvPlace", function()
    TV.PlacePrivate()
end)

--@ ================================================================================================
--@ วางจอใส (แอดมิน)
--@ ================================================================================================
function TV.PlaceBoard(group, width)
    if TV.Busy then return end
    local F = Config.Board.Free
    local lim = { minW = F.MinWidth, maxW = F.MaxWidth, minH = F.MinHeight or 0.3, maxH = F.MaxHeight or 12.0 }
    local w = math.max(lim.minW, math.min(lim.maxW, width or F.DefaultWidth))
    Begin()
    local result = AimPanel("<b>วางจอใส</b> กลุ่ม: " .. tostring(group), w, math.max(lim.minH, w * 9 / 16), lim)
    Finish()
    if not result then return TV.OpenAdmin("boards") end
    result.group = group
    local res = lib.callback.await(script .. ":sv:admin", false, "createFree", result)
    if res and res.ok then TV.Notify("success", "สร้างจอใสแล้ว") else TV.Notify("error", res and res.msg or "สร้างไม่สำเร็จ") end
    TV.OpenAdmin("boards")
end

--@ /tvpos : เล็งจอแผ่นแล้วได้บรรทัดสำหรับ Config.Screens (print F8 + ก๊อปให้)
RegisterCommand(Config.Command.ScreenPos or "tvpos", function(_, args)
    if TV.Busy or TV.UiOpen then return end
    local check = lib.callback.await(script .. ":sv:admin", false, "list", {})
    if not check or not check.ok then return TV.Notify("error", "เฉพาะแอดมิน") end
    local mode = args[1] == "warp" and "warp" or "tv"
    local w = 4.0
    Begin()
    local r = AimPanel("<b>หาพิกัดจอแผ่น</b> (" .. mode .. ")", w, w * 9 / 16, { minW = 0.2, maxW = 60.0, minH = 0.2, maxH = 60.0 })
    Finish()
    if not r then return end
    local line = ('{ id = "screen_%d", mode = "%s", coords = vector3(%.2f, %.2f, %.2f), heading = %.1f, width = %.2f, height = %.2f%s },')
        :format(GetCloudTimeAsInt() % 100000, mode, r.x, r.y, r.z, r.h, r.w, r.ht, mode == "warp" and ', group = "warp1"' or "")
    print("^2[bit_tv] วางบรรทัดนี้ใน Config.Screens :^7")
    print(line)
    SendNUIMessage({ action = "copy", text = line })
    TV.Notify("success", "ก๊อปบรรทัด config แล้ว (ดูใน F8 ด้วย) วางใน Config.Screens แล้วรีสคริปต์", 7000)
end, false)

--@ ================================================================================================
--@ แตะจอ : เล็งที่จอแล้วคลิก = คลิกในเบราว์เซอร์ของจอ (กด Skip โฆษณา / ปุ่มในตัวเล่น)
--@ มีผลกับจอในเครื่องตัวเองเท่านั้น (โฆษณาแต่ละคนก็ไม่เหมือนกันอยู่แล้ว)
--@ ================================================================================================
local function Dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function Cross(a, b) return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end

--@ ยิงเส้นจากกล้องไปชนจอ -> u, v (0-1) และจุดชน
local function HitScreen(tl, tr, br, bl)
    local o, dir = GetGameplayCamCoord(), CamDir()
    local ex, ey = tr - tl, bl - tl
    local n = Cross(ex, ey)
    local den = Dot(dir, n)
    if math.abs(den) < 1e-6 then return nil end
    local t = Dot(tl - o, n) / den
    if t <= 0 or t > 30.0 then return nil end
    local p = o + dir * t
    local d = p - tl
    local u, v = Dot(d, ex) / Dot(ex, ex), Dot(d, ey) / Dot(ey, ey)
    if u < 0 or u > 1 or v < 0 or v > 1 then return nil end
    return u, v, p
end

--@ คนที่คุมทีวีได้คลิก -> จอของเรากดตำแหน่งเดียวกันด้วย
RegisterNetEvent(script .. ":cl:click", function(key, u, v, from)
    if from == GetPlayerServerId(PlayerId()) then return end
    local dui = TV.ActiveDui(key)
    if not dui then return end
    local res = TV.Resolution
    local x, y = math.floor(u * res.w), math.floor(v * res.h)
    SendDuiMouseMove(dui, x, y)
    SendDuiMouseDown(dui, "left")
    Wait(60)
    SendDuiMouseUp(dui, "left")
end)

--@ mirror = true : คนนี้คุมทีวีได้ คลิกจะถูกส่งไปกดบนจอของทุกคนที่ดูอยู่ด้วย
function TV.Touch(key, mirror)
    if TV.Busy then return end
    Begin()
    TV.Hint({
        "<b>แตะจอ</b>",
        "เล็งจุดสีบนจอ แล้วคลิกซ้าย = กด (เช่น Skip โฆษณา)",
        mirror and "<b>คลิกของคุณจะกดบนจอของทุกคนที่ดูอยู่ด้วย</b>" or "คลิกมีผลเฉพาะจอของคุณ",
        "ลูกกลิ้ง = เลื่อนในจอ",
        "คลิกขวา / Backspace = ออก",
    })
    local meta = TV.KeyMeta(key)
    local res = TV.Resolution
    local down = false
    while true do
        BlockControls()
        DisablePlayerFiring(PlayerId(), true)
        local dui = TV.ActiveDui(key)
        local tl, tr, br, bl, uv = TV.ScreenCornersOf(key)
        if not dui or not tl then
            TV.Notify("error", "จออยู่ไกลเกินไป")
            break
        end
        local u, v, p = HitScreen(tl, tr, br, bl)
        if u then
            --@ จอแผ่นแบบ cover ตัดขอบ texture : แปลงจุดบนแผ่น -> จุดในเบราว์เซอร์
            u = uv[1] + u * (uv[2] - uv[1])
            v = uv[3] + v * (uv[4] - uv[3])
            local x, y = math.floor(u * res.w), math.floor(v * res.h)
            SendDuiMouseMove(dui, x, y)
            DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.025, 0.025, 0.025, 0, 182, 176, 230, false, false, 2, false, nil, nil, false)
            if Pressed(24) then
                SendDuiMouseDown(dui, "left")
                down = true
                if mirror then TriggerServerEvent(script .. ":sv:click", key, meta, u, v) end
            end
            if Pressed(14) then SendDuiMouseWheel(dui, -120, 0) end
            if Pressed(15) then SendDuiMouseWheel(dui, 120, 0) end
        end
        if down and IsDisabledControlJustReleased(0, 24) then
            SendDuiMouseUp(dui, "left")
            down = false
        end
        if Pressed(25) or Pressed(194) or Pressed(202) then break end
        Wait(0)
    end
    local dui = TV.ActiveDui(key)
    if down and dui then SendDuiMouseUp(dui, "left") end
    Finish()
end

--@ ================================================================================================
--@ จูนตำแหน่งจอของทีวีแต่ละรุ่น (แอดมิน) -> print บรรทัด config
--@ ================================================================================================
RegisterCommand(Config.Command.Calibrate, function()
    if TV.Busy or TV.UiOpen then return end
    local check = lib.callback.await(script .. ":sv:admin", false, "list", {})
    if not check or not check.ok then return TV.Notify("error", "เฉพาะแอดมิน") end
    local _, ent = TV.FindNearestTv(5.0)
    if not ent then return TV.Notify("error", "ไม่พบทีวีในระยะ 5 เมตร") end

    local hash = Shared.ModelHash(GetEntityModel(ent))
    local cfg = Shared.Models[hash]
    local fr, cx, y, cz, w, h, _, rot = TV.TvScreen(ent)
    --@ ถ้าเคยจูนแล้วเริ่มจากค่าเดิม (offset.y ตามที่บันทึก ไม่ใช่ฝั่งที่ยืน)
    local saved = TV.Calib[hash] or cfg.screen
    local s = saved and { offset = saved.offset, width = saved.width, height = saved.height, rot90 = saved.rot90 == true }
        or { offset = vector3(cx, y, cz), width = w, height = h, rot90 = rot }
    TV.CalibOverride[hash] = s

    Begin()
    TV.Hint({
        "<b>จูนจอ</b> " .. cfg.model,
        "← → = ซ้าย/ขวา   ↑ ↓ = ขึ้น/ลง",
        "Q / E = หน้า/หลัง",
        "ลูกกลิ้ง = กว้าง   PgUp / PgDn = สูง",
        "G = หมุนจอ 90°   Shift = ละเอียด",
        "Enter = บันทึก (ทีวีรุ่นนี้ทุกเครื่อง ทุกคนเห็นทันที)",
        "Delete = กลับเป็นค่าอัตโนมัติ   Backspace = ยกเลิก",
    })

    while true do
        BlockControls()
        DisableControlAction(0, 38, true)
        DisableControlAction(0, 10, true)
        DisableControlAction(0, 11, true)
        DisableControlAction(0, 47, true)
        DisableControlAction(0, 178, true)
        if Pressed(47) then s.rot90 = not s.rot90 end
        local st = Shift() and 0.002 or 0.01
        local o = s.offset
        if Held(175) then o = o + vector3(st, 0, 0) end
        if Held(174) then o = o - vector3(st, 0, 0) end
        if Held(172) then o = o + vector3(0, 0, st) end
        if Held(173) then o = o - vector3(0, 0, st) end
        if Held(44) then o = o + vector3(0, st, 0) end
        if Held(38) then o = o - vector3(0, st, 0) end
        if Pressed(15) then s.width = s.width + st * 3 end
        if Pressed(14) then s.width = math.max(0.05, s.width - st * 3) end
        if Held(10) then s.height = s.height + st end
        if Held(11) then s.height = math.max(0.05, s.height - st) end
        s.offset = o

        local f2, x2, y2, z2, w2, h2, side = TV.TvScreen(ent)
        local a, b, c, d = TV.Corners(f2, x2, y2, z2, w2, h2, side)
        Outline(a, b, c, d, 255, 180, 40)

        if Pressed(191) or Pressed(178) then
            local data = nil
            if Pressed(191) then
                data = { x = s.offset.x, y = s.offset.y, z = s.offset.z, w = s.width, h = s.height, rot = s.rot90 == true }
            end
            local res = lib.callback.await(script .. ":sv:calibSave", false, hash, data)
            if res and res.ok then
                TV.Notify("success", data and ("บันทึกจอรุ่น " .. cfg.model .. " แล้ว") or "กลับเป็นค่าอัตโนมัติแล้ว")
                break
            end
            TV.Notify("error", res and res.msg or "บันทึกไม่สำเร็จ")
        elseif Pressed(194) or Pressed(202) then
            break
        end
        if not DoesEntityExist(ent) then break end
        Wait(0)
    end
    TV.CalibOverride[hash] = nil
    Finish()
end, false)
