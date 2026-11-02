--@ ================================================================================================
--@ กดค้าง Config.Click.Key (Alt ซ้าย) = เมาส์โผล่ -> คลิกที่จอ = เปิด UI เหมือนกด E
--@ ทำงานเฉพาะตอนกดค้าง : ไม่กดก็ไม่มี loop ต่อเฟรม (เช็คปุ่มทุก 0 ms แต่ไม่ทำอะไรอย่างอื่น)
--@ ================================================================================================
if not (Config.Click and Config.Click.Enable) then
    print("^3[bit_tv] Alt+คลิก ปิดอยู่ (Config.Click.Enable)^7")
    return
end
print("^2[bit_tv] click.lua loaded : กด " .. tostring(Config.Click.Key or "LMENU") .. " ค้าง แล้วคลิกที่จอ (/tvclick = เช็คสถานะ)^7")

local KEY = Config.Click.Control or 19
local RANGE = Config.Click.Distance or 8.0

--@ ปุ่มผ่าน RegisterKeyMapping : ติดแม้สคริปต์อื่นปิด control 19 ไว้ (ผู้เล่นเปลี่ยนปุ่มเองได้ใน ตั้งค่า > ปุ่มลัด > FiveM)
local MapHeld = false
RegisterCommand("+bit_tv_click", function()
    MapHeld = true
    if Config.Debug then print("[bit_tv] +bit_tv_click (กดปุ่ม)") end
end, false)
RegisterCommand("-bit_tv_click", function() MapHeld = false end, false)
RegisterKeyMapping("+bit_tv_click", "TV : กดค้างแล้วคลิกที่จอ", "keyboard", Config.Click.Key or "LMENU")

local function IsHeld()
    return MapHeld or IsControlPressed(0, KEY) or IsDisabledControlPressed(0, KEY)
end

--@ อยู่ในโซนที่ใช้ Alt+คลิกได้ไหม (ไม่ตั้งโซน = ได้ทุกที่) -> ok, ชื่อโซน
local ZONES = Config.Click.Zones or {}
local function InZone()
    if #ZONES == 0 then return true end
    local p = GetEntityCoords(PlayerPedId())
    for i = 1, #ZONES do
        local z = ZONES[i]
        local c = z.coords
        local dx, dy = p.x - c.x, p.y - c.y
        if dx * dx + dy * dy <= z.radius * z.radius and (not z.minZ or p.z >= z.minZ) and (not z.maxZ or p.z <= z.maxZ) then
            return true, z.name
        end
    end
    return false
end
local OUTLINE = { 0, 182, 176 }

--@ /tvclick : บอกว่าทำไมโหมดคลิกไม่ทำงาน
RegisterCommand("tvclick", function()
    local inZone, zoneName = InZone()
    print(("[bit_tv] held=%s map=%s ctrl=%s disabled=%s | UiOpen=%s Busy=%s vehicle=%s pause=%s | zone=%s %s"):format(
        tostring(IsHeld()), tostring(MapHeld), tostring(IsControlPressed(0, KEY)), tostring(IsDisabledControlPressed(0, KEY)),
        tostring(TV.UiOpen), tostring(TV.Busy), tostring(IsPedInAnyVehicle(PlayerPedId(), false)), tostring(IsPauseMenuActive()),
        tostring(inZone), #ZONES == 0 and "(ไม่ได้ตั้งโซน = ทุกที่)" or tostring(zoneName or "-")))
    TV.Notify("info", ("Alt+คลิก : UiOpen=%s Busy=%s (ดูรายละเอียดใน F8)"):format(tostring(TV.UiOpen), tostring(TV.Busy)))
end, false)

--@ ปุ่มที่ปิดระหว่างกดค้าง : หมุนกล้อง / ยิง / ต่อย / เล็ง
local BLOCK = { 1, 2, 24, 25, 68, 69, 70, 91, 92, 106, 114, 140, 141, 142, 257, 263, 264, 330, 331 }

local function Dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function Cross(a, b) return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end

--@ เมาส์บนจอเกม -> เส้นจากกล้องออกไปในโลก
local function CursorRay()
    local cx, cy = GetControlNormal(0, 239), GetControlNormal(0, 240)
    local rot = GetFinalRenderedCamRot(2)
    local px, rz = math.rad(rot.x), math.rad(rot.z)
    local fwd = vector3(-math.sin(rz) * math.cos(px), math.cos(rz) * math.cos(px), math.sin(px))
    local right = vector3(math.cos(rz), math.sin(rz), 0.0)
    local up = Cross(right, fwd)
    local tanY = math.tan(math.rad(GetFinalRenderedCamFov()) * 0.5)
    local tanX = tanY * GetAspectRatio(false)
    local dir = fwd + right * ((cx * 2.0 - 1.0) * tanX) + up * ((1.0 - cy * 2.0) * tanY)
    return GetFinalRenderedCamCoord(), dir / #dir
end

--@ เส้นชนแผ่นจอ (TL TR BR BL) -> ระยะ t / nil
local function HitPanel(o, dir, tl, tr, bl)
    local ex, ey = tr - tl, bl - tl
    local n = Cross(ex, ey)
    local den = Dot(dir, n)
    if math.abs(den) < 1e-6 then return nil end
    local t = Dot(tl - o, n) / den
    if t <= 0 then return nil end
    local d = o + dir * t - tl
    local u, v = Dot(d, ex) / Dot(ex, ex), Dot(d, ey) / Dot(ey, ey)
    if u < 0 or u > 1 or v < 0 or v > 1 then return nil end
    return t
end

--@ จอที่คลิกได้รอบตัว (สแกนตอนกดค้างเท่านั้น ทุก 400 ms)
local function Candidates()
    local coords = GetEntityCoords(PlayerPedId())
    local list = {}
    for _, e in ipairs(GetGamePool("CObject")) do
        if Shared.Models[Shared.ModelHash(GetEntityModel(e))] then
            local p = GetEntityCoords(e)
            if #(coords - p) <= RANGE then
                local pid = TV.PropByEnt[e]
                list[#list + 1] = pid and ("p:" .. pid) or Shared.MapKey(GetEntityModel(e), p.x, p.y, p.z)
            end
        end
    end
    for key, b in pairs(TV.Boards) do
        if b.kind == "free" then
            local f = TV.FlatOf(key)
            if f and #(coords - vector3(f.x, f.y, f.z)) <= RANGE + math.max(f.w or 2.0, f.ht or 0.0) * 0.5 then
                list[#list + 1] = key
            end
        end
    end
    for key, c in pairs(Shared.Screens) do
        if #(coords - vector3(c.x, c.y, c.z)) <= c.range then list[#list + 1] = key end
    end
    for key, p in pairs(TV.Private) do
        if TV.Visible(key) and #(coords - vector3(p.x, p.y, p.z)) <= RANGE + math.max(p.w, p.ht) * 0.5 then list[#list + 1] = key end
    end
    return list
end

--@ เรียก native ตรงๆ (ชื่อฟังก์ชันใน Lua เปลี่ยนไปมาตามเวอร์ชัน)
local function ShowCursorThisFrame() Citizen.InvokeNative(0xAAE7CE1D63167423) end   --@ SET_MOUSE_CURSOR_THIS_FRAME
local function CursorStyle(n) Citizen.InvokeNative(0x8DB8CFFD58B62552, n) end       --@ SET_MOUSE_CURSOR_STYLE 1 ปกติ / 5 มือชี้

local function Outline(a, b, c, d)
    local r, g, bl = OUTLINE[1], OUTLINE[2], OUTLINE[3]
    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, r, g, bl, 255)
    DrawLine(b.x, b.y, b.z, c.x, c.y, c.z, r, g, bl, 255)
    DrawLine(c.x, c.y, c.z, d.x, d.y, d.z, r, g, bl, 255)
    DrawLine(d.x, d.y, d.z, a.x, a.y, a.z, r, g, bl, 255)
end

CreateThread(function()
    while true do
        local held = IsHeld()
        if not held or TV.UiOpen or TV.Busy or IsPauseMenuActive() or IsPedInAnyVehicle(PlayerPedId(), false) or not InZone() then
            if held and Config.Debug then
                print(("[bit_tv] กดอยู่แต่ไม่เปิดโหมดคลิก : UiOpen=%s Busy=%s vehicle=%s inZone=%s"):format(tostring(TV.UiOpen), tostring(TV.Busy), tostring(IsPedInAnyVehicle(PlayerPedId(), false)), tostring((InZone()))))
            end
            Wait(held and 200 or 0)
        else
            if Config.Debug then print("[bit_tv] click mode on") end
            local list, lastScan = Candidates(), GetGameTimer()
            local hinted = nil
            while IsHeld() and not TV.UiOpen and not TV.Busy do
                if GetGameTimer() - lastScan > 400 and not InZone() then break end
                if GetGameTimer() - lastScan > 400 then
                    list, lastScan = Candidates(), GetGameTimer()
                end
                for i = 1, #BLOCK do DisableControlAction(0, BLOCK[i], true) end
                DisablePlayerFiring(PlayerId(), true)
                ShowCursorThisFrame()

                local o, dir = CursorRay()
                local best, bestT, bc
                for i = 1, #list do
                    local tl, tr, br, bl = TV.PanelCornersOf(list[i])
                    if tl then
                        local t = HitPanel(o, dir, tl, tr, bl)
                        if t and (not bestT or t < bestT) then best, bestT, bc = list[i], t, { tl, tr, br, bl } end
                    end
                end

                --@ บอกผู้เล่นว่าโหมดคลิกทำงาน (ส่งเฉพาะตอนสถานะเปลี่ยน)
                local h = best and "on" or (#list > 0 and "near" or "none")
                if h ~= hinted then
                    hinted = h
                    TV.Hint({ h == "on" and "<b>คลิกซ้าย</b> = เปิดจอนี้" or (h == "near" and "<b>ALT</b> เอาเมาส์ชี้ที่จอ แล้วคลิก" or "<b>ALT</b> ไม่มีจอในระยะ") })
                end

                if best then
                    CursorStyle(5)
                    Outline(bc[1], bc[2], bc[3], bc[4])
                    if IsDisabledControlJustPressed(0, 24) then
                        TV.OpenScreen(best)
                        break
                    end
                else
                    CursorStyle(1)
                end
                Wait(0)
            end
            if not TV.Busy then TV.Hint(nil) end
            --@ ปล่อยปุ่ม/เปิด UI แล้ว : รอปล่อยปุ่มก่อน กันเปิดซ้ำทันทีที่ปิด UI
            while IsHeld() do
                if not TV.UiOpen then for i = 1, #BLOCK do DisableControlAction(0, BLOCK[i], true) end end
                Wait(0)
            end
        end
    end
end)
