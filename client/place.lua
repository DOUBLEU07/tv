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
--@ วางจอใส (แอดมิน)
--@ ================================================================================================
function TV.PlaceBoard(group, width)
    if TV.Busy then return end
    local F = Config.Board.Free
    Begin()
    local ped = PlayerPedId()
    local heading = (GetEntityHeading(ped) + 180.0) % 360.0
    local w = math.max(F.MinWidth, math.min(F.MaxWidth, width or F.DefaultWidth))
    local zOff = 0.0

    TV.Hint({
        "<b>วางจอใส</b> กลุ่ม: " .. tostring(group),
        "เมาส์ = เล็งตำแหน่ง",
        "ลูกกลิ้ง = หมุน (Shift = ละเอียด)",
        "↑ ↓ = ยก/ลด   ← → = ขนาด",
        "Enter = วาง   Backspace = ยกเลิก",
    })

    local result = nil
    while result == nil do
        BlockControls()
        local step = Shift() and 1.0 or 5.0
        if Pressed(14) then heading = heading - step end
        if Pressed(15) then heading = heading + step end
        if Held(172) then zOff = zOff + (Shift() and 0.005 or 0.03) end
        if Held(173) then zOff = zOff - (Shift() and 0.005 or 0.03) end
        if Held(175) then w = math.min(F.MaxWidth, w + (Shift() and 0.005 or 0.03)) end
        if Held(174) then w = math.max(F.MinWidth, w - (Shift() and 0.005 or 0.03)) end

        local h = w * 9 / 16
        local hit = Raycast(25.0)
        local c = hit + vector3(0.0, 0.0, h * 0.5 + zOff)
        local fr = TV.HeadingFrame(c.x, c.y, c.z, heading)
        local a, b, cc, d = TV.Corners(fr, 0.0, 0.0, 0.0, w, h, 1)
        Outline(a, b, cc, d, 13, 207, 199)

        if Pressed(191) then
            result = { x = c.x, y = c.y, z = c.z, h = heading % 360.0, w = w }
        elseif Pressed(194) or Pressed(202) then
            result = false
        end
        Wait(0)
    end

    Finish()
    if not result then return TV.OpenAdmin("boards") end
    result.group = group
    local res = lib.callback.await(script .. ":sv:admin", false, "createFree", result)
    if res and res.ok then TV.Notify("success", "สร้างจอใสแล้ว") else TV.Notify("error", res and res.msg or "สร้างไม่สำเร็จ") end
    TV.OpenAdmin("boards")
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
