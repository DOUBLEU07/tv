local script = GetCurrentResourceName()
local PAGE = Config.ScreenPage or ("nui://" .. script .. "/web/screen/screen.html")
PAGE = PAGE .. (PAGE:find("?", 1, true) and "&" or "?") .. "res=" .. script
local RES = Config.Render.Resolution

--@ ================================================================================================
--@ เบราว์เซอร์ (DUI) : สร้างเฉพาะจอที่อยู่ใกล้ ใช้วนกันได้ ไม่ได้ใช้นานเกิน IdleDestroy = ทำลาย
--@ ================================================================================================
local Slots = {}        --@ { dui, txd, txn, key, freeAt }
local Active = {}       --@ [key] = slot
local TxdCount = 0

local function NewSlot()
    TxdCount = TxdCount + 1
    local dui = CreateDui(PAGE, RES.w, RES.h)
    local txd = "bit_tv_" .. TxdCount
    local rt = CreateRuntimeTxd(txd)
    CreateRuntimeTextureFromDuiHandle(rt, "screen", GetDuiHandle(dui))
    local slot = { dui = dui, txd = txd, txn = "screen" }
    Slots[#Slots + 1] = slot
    return slot
end

local function Send(slot, msg)
    SendDuiMessage(slot.dui, json.encode(msg))
end

local function Acquire(key)
    for _, s in ipairs(Slots) do
        if not s.key then
            s.key, s.freeAt = key, nil
            return s
        end
    end
    local s = NewSlot()
    s.key = key
    return s
end

local function Release(key)
    local s = Active[key]
    if not s then return end
    Active[key] = nil
    s.key = nil
    s.freeAt = GetGameTimer()
    Send(s, { t = "idle" })
end

local function DestroyIdle()
    local now = GetGameTimer()
    for i = #Slots, 1, -1 do
        local s = Slots[i]
        if not s.key and s.freeAt and now - s.freeAt > Config.Render.IdleDestroy * 1000 then
            DestroyDui(s.dui)
            table.remove(Slots, i)
        end
    end
end

--@ ================================================================================================
--@ เรขาคณิตจอ
--@ frame = { pos, r(ขวา), f(หน้า), u(บน) } ; จอ = สี่เหลี่ยมบนระนาบ local y
--@ ================================================================================================
local DimCache = {}
TV.CalibOverride = {}   --@ [hash] = screen : place.lua ใช้ตอนกำลังจูน (เห็นคนเดียว)
TV.Calib = {}           --@ [hash] = screen : ค่าที่บันทึกแล้วจากเซิร์ฟ (ทุกคนใช้)

--@ ค่าจากเซิร์ฟ { x, y, z, w, h, rot } -> รูปแบบเดียวกับ screen ใน config
function TV.SetCalib(hashStr, c)
    local hash = tonumber(hashStr)
    if not hash then return end
    if not c then TV.Calib[hash] = nil return end
    TV.Calib[hash] = { offset = vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0), width = c.w + 0.0, height = c.h + 0.0, rot90 = c.rot == true }
end

local function ModelDims(model)
    local d = DimCache[model]
    if d then return d end
    local mn, mx = GetModelDimensions(model)
    d = { mn = mn, mx = mx }
    DimCache[model] = d
    return d
end

--@ แกน local ของ entity : คำนวณจาก GetOffsetFromEntityInWorldCoords ตรงๆ
--@ (GetEntityMatrix คืนค่า forward/right สลับกับที่คิด ทำให้จอตั้งฉากกับทีวีและภาพกลับด้าน)
local function EntityFrame(ent)
    local o = GetOffsetFromEntityInWorldCoords(ent, 0.0, 0.0, 0.0)
    return {
        pos = o,
        r = GetOffsetFromEntityInWorldCoords(ent, 1.0, 0.0, 0.0) - o,
        f = GetOffsetFromEntityInWorldCoords(ent, 0.0, 1.0, 0.0) - o,
        u = GetOffsetFromEntityInWorldCoords(ent, 0.0, 0.0, 1.0) - o,
    }
end

local function HeadingFrame(x, y, z, h)
    local rad = math.rad(h)
    return {
        pos = vector3(x, y, z),
        r = vector3(math.cos(rad), math.sin(rad), 0.0),
        f = vector3(-math.sin(rad), math.cos(rad), 0.0),
        u = vector3(0.0, 0.0, 1.0),
    }
end
TV.HeadingFrame = HeadingFrame

local function ToWorld(fr, lx, ly, lz)
    return fr.pos + fr.r * lx + fr.f * ly + fr.u * lz
end

--@ หมุนกรอบ 90° รอบแกนตั้ง : x ใหม่ = y เดิม, y ใหม่ = -x เดิม
local function Rot90(fr)
    return { pos = fr.pos, r = fr.f, f = -fr.r, u = fr.u }
end

--@ ฝั่งที่กล้องอยู่ เทียบกับระนาบ y (1 = ฝั่งหน้า +y, -1 = ฝั่งหลัง)
local function CamSide(fr, planeY)
    local cam = GetFinalRenderedCamCoord()
    local d = cam - fr.pos
    local ly = d.x * fr.f.x + d.y * fr.f.y + d.z * fr.f.z
    return ly >= planeY and 1 or -1
end

--@ จอของทีวี (entity) -> frame, cx, y, cz, w, h, side
function TV.TvScreen(ent)
    local model = GetEntityModel(ent)
    local hash = Shared.ModelHash(model)
    local cfg = Shared.Models[hash]
    local scr = TV.CalibOverride[hash] or TV.Calib[hash] or (cfg and cfg.screen)
    local fr = EntityFrame(ent)
    if scr then
        if scr.rot90 then fr = Rot90(fr) end
        local o = scr.offset
        local side = CamSide(fr, o.y)
        return fr, o.x, o.y, o.z, scr.width, scr.height, side, scr.rot90 == true
    end
    local d = ModelDims(model)
    local mn, mx = d.mn, d.mx
    --@ จอหันไปทางแกนที่บางกว่า : โมเดลส่วนใหญ่บางตามแกน y ถ้าบางตามแกน x ให้หมุนกรอบ 90°
    local x1, x2, y1, y2 = mn.x, mx.x, mn.y, mx.y
    local rot = (mx.x - mn.x) < (mx.y - mn.y)
    if rot then
        fr = Rot90(fr)
        x1, x2, y1, y2 = mn.y, mx.y, -mx.x, -mn.x
    end
    local cx, cz = (x1 + x2) * 0.5, (mn.z + mx.z) * 0.5
    local w = (x2 - x1) * Config.TV.AutoInset.w
    local h = (mx.z - mn.z) * Config.TV.AutoInset.h
    local side = CamSide(fr, (y1 + y2) * 0.5)
    local y = side > 0 and (y2 + 0.012) or (y1 - 0.012)
    return fr, cx, y, cz, w, h, side, rot
end

--@ จอใส : สัดส่วน 16:9
function TV.FreeScreen(b)
    local fr = HeadingFrame(b.x, b.y, b.z, b.h or 0.0)
    local w = b.w or Config.Board.Free.DefaultWidth
    return fr, 0.0, 0.0, 0.0, w, w * 9 / 16, CamSide(fr, 0.0)
end

--@ มุมจอ TL TR BR BL (ซ้าย/ขวา ตามมุมมองคนดู ภาพจึงไม่กลับด้านไม่ว่าดูจากฝั่งไหน)
function TV.Corners(fr, cx, y, cz, w, h, side)
    local left, right = cx + side * w * 0.5, cx - side * w * 0.5
    local top, bot = cz + h * 0.5, cz - h * 0.5
    return ToWorld(fr, left, y, top), ToWorld(fr, right, y, top), ToWorld(fr, right, y, bot), ToWorld(fr, left, y, bot)
end

local function DrawQuad(a, b, c, d, txd, txn)
    --@ วาดทั้งสองหน้า (poly ถูก cull ตามทิศการเรียงจุด)
    DrawSpritePoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, 255, 255, 255, 255, txd, txn, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0)
    DrawSpritePoly(a.x, a.y, a.z, c.x, c.y, c.z, d.x, d.y, d.z, 255, 255, 255, 255, txd, txn, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0)
    DrawSpritePoly(a.x, a.y, a.z, c.x, c.y, c.z, b.x, b.y, b.z, 255, 255, 255, 255, txd, txn, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0)
    DrawSpritePoly(a.x, a.y, a.z, d.x, d.y, d.z, c.x, c.y, c.z, 255, 255, 255, 255, txd, txn, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0)
end

local function ScreenOf(key)
    local b = TV.Boards[key]
    if b and b.kind == "free" then return TV.FreeScreen(b) end
    local ent = TV.KeyEntity(key)
    if not ent then return nil end
    return TV.TvScreen(ent)
end

--@ ================================================================================================
--@ เนื้อหาที่ส่งเข้าจอ
--@ ================================================================================================
local function Falloff(d)
    local a = Config.Audio
    if d <= a.FullVolumeDistance then return 1.0 end
    if d >= a.MaxDistance then return 0.0 end
    return 1.0 - (d - a.FullVolumeDistance) / (a.MaxDistance - a.FullVolumeDistance)
end

local function BoardMessage(b, now)
    local q = TV.Queue[b.group] or {}
    local dur = Config.Board.Duration
    local cur, nextCount = nil, 0
    --@ ตัดของที่จบแล้วทิ้ง
    for i = #q, 1, -1 do
        if q[i].startAt + dur <= now then table.remove(q, i) end
    end
    for _, e in ipairs(q) do
        if e.startAt <= now then
            cur = cur or e
        else
            nextCount = nextCount + 1
        end
    end
    return {
        t = "board",
        rev = cur and ("p" .. cur.id) or "empty",
        post = cur and cur.post or nil,
        remain = cur and (cur.startAt + dur - now) or 0,
        dur = dur,
        next = nextCount,
        price = Config.Board.Price,
        kind = b.kind,
    }
end

local function VideoMessage(key, st, now, dist)
    local fall = Falloff(dist)
    local vol = (st.vol or 0) * (TV.Personal / 100.0) * fall
    return {
        t = "video",
        rev = key .. "|" .. tostring(st.id),
        seek = st.seek or 0,
        media = st.media,
        elapsed = math.max(0.0, now - st.startAt),
        vol = math.floor(vol + 0.5),
        audio = Shared.AudioControl[st.media.p],
        ytSmall = Config.TV.YouTubeNoAds and Config.TV.YouTubeNoAds.Enable and Config.TV.YouTubeNoAds.Width or nil,
    }
end

--@ ================================================================================================
--@ เลือกจอที่จะวาด (ทุก 250ms)
--@ ================================================================================================
local Draw = {}         --@ list ที่ thread วาดใช้ : { key, slot }

CreateThread(function()
    local lastIdle = 0
    while true do
        local coords = GetEntityCoords(PlayerPedId())
        local now = TV.ServerNow()
        local cand = {}

        for key, st in pairs(TV.Play) do
            if not TV.Boards[key] and st.media then
                local pos = TV.KeyPos(key)
                if pos then
                    local d = #(coords - pos)
                    --@ เว็บที่คุมเสียงไม่ได้ : วาดเฉพาะตอนอยู่ในระยะเสียง ออกนอกระยะ = ปิดทั้งจอ (เสียงหายด้วย)
                    local limit = Shared.AudioControl[st.media.p] and Config.Render.Distance or Config.Audio.MaxDistance
                    if TV.Personal <= 0 and not Shared.AudioControl[st.media.p] then limit = -1 end
                    if d <= limit then cand[#cand + 1] = { key = key, d = d, st = st } end
                end
            end
        end
        for key, b in pairs(TV.Boards) do
            local d = #(coords - vector3(b.x, b.y, b.z))
            if d <= Config.Render.Distance then cand[#cand + 1] = { key = key, d = d, board = b } end
        end
        table.sort(cand, function(a, b) return a.d < b.d end)

        local want = {}
        local list = {}
        for _, c in ipairs(cand) do
            if #list >= Config.Render.MaxScreens then break end
            --@ ทีวีที่ object ยังไม่โหลด (ไกล/อยู่ใน interior อื่น) ข้าม
            if c.board and c.board.kind == "free" or TV.KeyEntity(c.key) then
                want[c.key] = true
                local slot = Active[c.key] or Acquire(c.key)
                Active[c.key] = slot
                list[#list + 1] = { key = c.key, slot = slot }
                if c.board then
                    Send(slot, BoardMessage(c.board, now))
                else
                    Send(slot, VideoMessage(c.key, c.st, now, c.d))
                end
            end
        end
        for key in pairs(Active) do
            if not want[key] then Release(key) end
        end
        Draw = list

        if GetGameTimer() - lastIdle > 5000 then
            lastIdle = GetGameTimer()
            DestroyIdle()
        end
        Wait(250)
    end
end)

--@ วาดทุกเฟรมเฉพาะตอนมีจออยู่ใกล้
CreateThread(function()
    while true do
        if #Draw == 0 then
            Wait(300)
        else
            for i = 1, #Draw do
                local it = Draw[i]
                local fr, cx, y, cz, w, h, side = ScreenOf(it.key)
                if fr then
                    local a, b, c, d = TV.Corners(fr, cx, y, cz, w, h, side)
                    DrawQuad(a, b, c, d, it.slot.txd, it.slot.txn)
                end
            end
            Wait(0)
        end
    end
end)

--@ ให้โหมดแตะจอ (place.lua) ใช้
function TV.ActiveDui(key)
    local s = Active[key]
    return s and s.dui or nil
end

function TV.ScreenCornersOf(key)
    local fr, cx, y, cz, w, h, side = ScreenOf(key)
    if not fr then return nil end
    return TV.Corners(fr, cx, y, cz, w, h, side)
end

TV.Resolution = RES

AddEventHandler("onResourceStop", function(res)
    if res ~= script then return end
    for _, s in ipairs(Slots) do DestroyDui(s.dui) end
end)
