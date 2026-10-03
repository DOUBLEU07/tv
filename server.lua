local ESX = exports["es_extended"]:getSharedObject()
local script = GetCurrentResourceName()

--@ ================================================================================================
--@ state (หน่วยความจำอย่างเดียว ไม่ลง database)
--@ key ของจอ : "m:<hash>:<x>:<y>:<z>" ทีวีในแมพ / "p:<id>" ทีวีที่วางเอง / "f:<id>" จอใส
--@ ================================================================================================
local Play = {}         --@ [key] = { media, startAt, vol, by, byIdent, at(os.time) }
local PlayCount = 0
local Props = {}        --@ [id] = { id, model, x, y, z, h, owner(identifier), ownerName }
local NextProp = 1
local Boards = {}       --@ [key] = { key, group, kind = "tv"|"free", x, y, z, h, w, model }
local NextBoard = 1
local Queue = {}        --@ [group] = { { id, post, startAt }, ... } อนุมัติแล้ว เรียงตามเวลาขึ้นจอ
local Pending = {}      --@ [id] = { id, group, boardKey, src, ident, name, post, paid, at }
local NextPost = 1
local Refund = {}       --@ [identifier] = เงินคืนที่ค้าง (คนออกเกมตอนโดนปฏิเสธ)
local Admins = {}       --@ [src] = true : แอดมินที่ออนไลน์ (ไว้แจ้งเตือนโพสต์ใหม่ ไม่ต้องวนผู้เล่นทั้งเซิร์ฟ)
local RateLast = {}     --@ [src] = { [action] = GetGameTimer() }

local function Now()
    return GetGameTimer() / 1000.0
end

local function DebugPrint(...)
    if Config.Debug then print("^5[" .. script .. "]^7", ...) end
end

local function Notify(src, kind, text, time)
    TriggerClientEvent("bit_itemnotify:AddNotify", src, { type = kind, text = text, time = time or 4000 })
end

local function GetX(src)
    return ESX.GetPlayerFromId(src)
end

local function IsAdmin(src)
    local xPlayer = GetX(src)
    local ok = xPlayer and Config.AdminGroups[xPlayer.getGroup()] == true or false
    Admins[src] = ok or nil
    return ok
end

local function NameOf(xPlayer, src)
    if xPlayer and xPlayer.getName then
        local ok, n = pcall(xPlayer.getName)
        if ok and n and n ~= "" then return n end
    end
    return GetPlayerName(src) or ("ID " .. src)
end

local function RateOk(src, action, sec)
    local now = GetGameTimer()
    local t = RateLast[src]
    if not t then t = {}; RateLast[src] = t end
    if t[action] and now - t[action] < sec * 1000 then return false end
    t[action] = now
    return true
end

local function Log(kind, src, content)
    if not Config.Log.Enable then return end
    pcall(function()
        exports["azael_dc-serverlogs"]:insertData({
            event = Config.Log.Event,
            content = content,
            source = src or 0,
            color = Config.Log.Color[kind] or 1,
            options = { codeblock = false },
        })
    end)
end

local function PedPos(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function Near(src, pos, dist)
    local p = PedPos(src)
    return p and #(p - pos) <= dist
end

--@ ================================================================================================
--@ หาจอจาก key (ตำแหน่งจริงสำหรับเช็คระยะ)
--@ ================================================================================================
local function ScreenPos(key, meta)
    local kind = key:sub(1, 1)
    if kind == "p" then
        local p = Props[tonumber(key:sub(3))]
        return p and vector3(p.x, p.y, p.z), p
    elseif kind == "f" then
        local b = Boards[key]
        return b and vector3(b.x, b.y, b.z)
    elseif kind == "m" then
        --@ ทีวีในแมพ : เซิร์ฟไม่เห็น object ในแมพ เลยสร้าง key ใหม่จาก model+พิกัดที่ client ส่งมา ต้องตรงกัน
        if type(meta) ~= "table" then return nil end
        local x, y, z, model = tonumber(meta.x), tonumber(meta.y), tonumber(meta.z), tonumber(meta.model)
        if not (x and y and z and model) then return nil end
        if not Shared.Models[Shared.ModelHash(model)] then return nil end
        if Shared.MapKey(model, x, y, z) ~= key then return nil end
        return vector3(x, y, z)
    end
    return nil
end

local function CanControl(src, key)
    if IsAdmin(src) then return true end
    if key:sub(1, 1) == "p" then
        local p = Props[tonumber(key:sub(3))]
        local xPlayer = GetX(src)
        if p and xPlayer and p.owner == xPlayer.identifier then return true end
    end
    return Config.TV.ControlWho == "everyone"
end

--@ ================================================================================================
--@ ทีวีเปิดลิงก์
--@ ================================================================================================
local function SetPlay(key, state)
    if Play[key] and not state then PlayCount = PlayCount - 1 end
    if not Play[key] and state then PlayCount = PlayCount + 1 end
    Play[key] = state
    --@ เปลี่ยนเฉพาะตอนมีคนกด (นานๆครั้ง) ส่งทุกคนครั้งเดียว ให้ client คนที่อยู่ใกล้จอตัดสินใจเองว่าจะวาด
    TriggerClientEvent(script .. ":cl:play", -1, key, state, Now())
end

local function PublicPlay(state)
    if not state then return nil end
    return { media = state.media, startAt = state.startAt, vol = state.vol, by = state.by }
end

lib.callback.register(script .. ":sv:tvInfo", function(src, key, meta)
    if type(key) ~= "string" then return nil end
    local pos = ScreenPos(key, meta)
    if not pos or not Near(src, pos, Config.InteractDistance + 4.0) then return nil end
    if Boards[key] then return { board = true } end

    local res = {
        play = PublicPlay(Play[key]),
        now = Now(),
        canControl = CanControl(src, key),
        canRemove = false,
        defaultVolume = Config.TV.DefaultVolume,
    }
    if key:sub(1, 1) == "p" then
        local p = Props[tonumber(key:sub(3))]
        local xPlayer = GetX(src)
        res.canRemove = p and (IsAdmin(src) or (xPlayer and p.owner == xPlayer.identifier)) or false
        res.ownerName = p and p.ownerName
    end
    return res
end)

lib.callback.register(script .. ":sv:tvPlay", function(src, key, meta, url, vol)
    if type(key) ~= "string" then return { ok = false, msg = "ไม่พบทีวี" } end
    local pos = ScreenPos(key, meta)
    if not pos or not Near(src, pos, Config.InteractDistance + 4.0) then return { ok = false, msg = "อยู่ไกลทีวีเกินไป" } end
    if Boards[key] then return { ok = false, msg = "ทีวีนี้เป็นจอวาร์ป" } end
    if not CanControl(src, key) then return { ok = false, msg = "คุณไม่มีสิทธิ์คุมทีวีนี้" } end
    if not RateOk(src, "play", Config.TV.Cooldown) then return { ok = false, msg = "ใจเย็นๆ กดถี่เกินไป" } end
    if not Play[key] and PlayCount >= Config.TV.MaxActive then return { ok = false, msg = "ทีวีทั้งเซิร์ฟเปิดเต็มแล้ว" } end

    local media, err = Shared.ParseMedia(url)
    if not media then return { ok = false, msg = err } end

    local xPlayer = GetX(src)
    vol = math.floor(math.max(0, math.min(100, tonumber(vol) or Config.TV.DefaultVolume)))
    SetPlay(key, {
        media = media,
        startAt = Now() - (media.s or 0),
        vol = vol,
        by = NameOf(xPlayer, src),
        byIdent = xPlayer and xPlayer.identifier,
        at = os.time(),
    })
    Log("play", src, ("เปิดทีวี `%s`\n%s"):format(key, media.url))
    return { ok = true }
end)

lib.callback.register(script .. ":sv:tvStop", function(src, key, meta)
    if type(key) ~= "string" or not Play[key] then return { ok = false, msg = "ทีวีไม่ได้เปิดอยู่" } end
    local pos = ScreenPos(key, meta)
    if not pos or not Near(src, pos, Config.InteractDistance + 4.0) then return { ok = false, msg = "อยู่ไกลทีวีเกินไป" } end
    if not CanControl(src, key) then return { ok = false, msg = "คุณไม่มีสิทธิ์คุมทีวีนี้" } end
    SetPlay(key, nil)
    Log("stop", src, ("ปิดทีวี `%s`"):format(key))
    return { ok = true }
end)

lib.callback.register(script .. ":sv:tvVolume", function(src, key, meta, vol)
    local state = type(key) == "string" and Play[key]
    if not state then return { ok = false } end
    local pos = ScreenPos(key, meta)
    if not pos or not Near(src, pos, Config.InteractDistance + 4.0) then return { ok = false, msg = "อยู่ไกลทีวีเกินไป" } end
    if not CanControl(src, key) then return { ok = false, msg = "คุณไม่มีสิทธิ์คุมทีวีนี้" } end
    if not RateOk(src, "vol", 0.4) then return { ok = false } end
    state.vol = math.floor(math.max(0, math.min(100, tonumber(vol) or state.vol)))
    TriggerClientEvent(script .. ":cl:volume", -1, key, state.vol)
    return { ok = true }
end)

--@ เปิดค้างนานเกิน = ปิดเอง (วนเฉพาะทีวีที่เปิดอยู่ ไม่ได้วนผู้เล่น)
CreateThread(function()
    while true do
        Wait(60000)
        local limit = os.time() - Config.TV.AutoStopMinutes * 60
        for key, st in pairs(Play) do
            if st.at < limit then SetPlay(key, nil) end
        end
    end
end)

--@ ================================================================================================
--@ วางทีวีเอง
--@ ================================================================================================
local PlaceModels = {}
for _, m in ipairs(Config.TV.Place.Models) do PlaceModels[Shared.ModelHash(m.model)] = true end

local function CountOwned(ident)
    local n, total = 0, 0
    for _, p in pairs(Props) do
        total = total + 1
        if p.owner == ident then n = n + 1 end
    end
    return n, total
end

lib.callback.register(script .. ":sv:propPlace", function(src, model, x, y, z, h)
    local cfg = Config.TV.Place
    if not cfg.Enable then return { ok = false, msg = "ปิดระบบวางทีวีอยู่" } end
    local admin = IsAdmin(src)
    if cfg.Who ~= "everyone" and not admin then return { ok = false, msg = "เฉพาะแอดมิน" } end
    model, x, y, z, h = tonumber(model), tonumber(x), tonumber(y), tonumber(z), tonumber(h)
    if not (model and x and y and z and h) then return { ok = false, msg = "ข้อมูลไม่ถูกต้อง" } end
    model = Shared.ModelHash(model)
    if not PlaceModels[model] then return { ok = false, msg = "รุ่นนี้วางไม่ได้" } end
    if not Near(src, vector3(x, y, z), cfg.MaxDistance + 2.0) then return { ok = false, msg = "วางไกลตัวเกินไป" } end
    if not RateOk(src, "place", 2) then return { ok = false, msg = "ใจเย็นๆ" } end

    local xPlayer = GetX(src)
    if not xPlayer then return { ok = false } end
    local owned, total = CountOwned(xPlayer.identifier)
    if total >= cfg.MaxTotal then return { ok = false, msg = "ทีวีทั้งเซิร์ฟเต็มแล้ว" } end
    if not admin and owned >= cfg.MaxPerPlayer then return { ok = false, msg = ("วางได้สูงสุด %d เครื่อง"):format(cfg.MaxPerPlayer) } end

    local id = NextProp
    NextProp = NextProp + 1
    local p = { id = id, model = model, x = x, y = y, z = z, h = h % 360.0, owner = xPlayer.identifier, ownerName = NameOf(xPlayer, src) }
    Props[id] = p
    TriggerClientEvent(script .. ":cl:prop", -1, id, p)
    Log("place", src, ("วางทีวี #%d (%d) ที่ %.1f, %.1f, %.1f"):format(id, model, x, y, z))
    return { ok = true, id = id }
end)

local function RemoveBoard(key)
    if not Boards[key] then return end
    Boards[key] = nil
    TriggerClientEvent(script .. ":cl:board", -1, key, nil)
end

local function RemoveProp(id)
    local key = "p:" .. id
    Props[id] = nil
    if Play[key] then SetPlay(key, nil) end
    RemoveBoard(key)
    TriggerClientEvent(script .. ":cl:prop", -1, id, nil)
end

lib.callback.register(script .. ":sv:propRemove", function(src, id)
    id = tonumber(id)
    local p = id and Props[id]
    if not p then return { ok = false, msg = "ไม่พบทีวี" } end
    local xPlayer = GetX(src)
    if not IsAdmin(src) and not (xPlayer and xPlayer.identifier == p.owner) then return { ok = false, msg = "ไม่ใช่ทีวีของคุณ" } end
    if not Near(src, vector3(p.x, p.y, p.z), 8.0) then return { ok = false, msg = "อยู่ไกลทีวีเกินไป" } end
    RemoveProp(id)
    Log("remove", src, ("เก็บทีวี #%d"):format(id))
    return { ok = true }
end)

--@ ================================================================================================
--@ จอวาร์ป : คิว
--@ ================================================================================================
local function PruneQueue(group)
    local q = Queue[group]
    if not q then return {} end
    local now = Now()
    local keep = {}
    for _, e in ipairs(q) do
        if e.startAt + Config.Board.Duration > now then keep[#keep + 1] = e end
    end
    Queue[group] = keep
    return keep
end

local function GroupHasBoard(group)
    for _, b in pairs(Boards) do
        if b.group == group then return true end
    end
    return false
end

local function PayBack(ident, src, amount, reason)
    if amount <= 0 then return end
    local xPlayer = src and GetX(src)
    if xPlayer and xPlayer.identifier == ident then
        xPlayer.addAccountMoney(Config.Board.Account, amount, "bit_tv:refund")
        Notify(src, "info", ("%s คืนเงิน $%s"):format(reason, ESX.Math and ESX.Math.GroupDigits(amount) or amount))
        return
    end
    Refund[ident] = (Refund[ident] or 0) + amount
end

local function PendingList()
    local list = {}
    for _, p in pairs(Pending) do
        list[#list + 1] = { id = p.id, group = p.group, name = p.name, post = p.post, paid = p.paid, at = p.at }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function BoardList()
    local list = {}
    for _, b in pairs(Boards) do
        local q = PruneQueue(b.group)
        list[#list + 1] = { key = b.key, group = b.group, kind = b.kind, x = b.x, y = b.y, z = b.z, queue = #q }
    end
    table.sort(list, function(a, b) return a.group == b.group and a.key < b.key or a.group < b.group end)
    return list
end

local function PostCard(p)
    return { name = p.name, img = p.img, text = p.text, ig = p.ig, fb = p.fb, tt = p.tt }
end

lib.callback.register(script .. ":sv:boardInfo", function(src, key, meta)
    local b = type(key) == "string" and Boards[key]
    if not b then return nil end
    local pos = ScreenPos(key, meta) or vector3(b.x, b.y, b.z)
    if not Near(src, pos, Config.InteractDistance + 6.0) then return nil end
    local q = PruneQueue(b.group)
    return {
        group = b.group,
        price = Config.Board.Price,
        queue = #q,
        wait = #q > 0 and math.max(0, math.floor(q[#q].startAt + Config.Board.Duration - Now())) or 0,
        limits = { text = Config.Board.TextMax, name = Config.Board.NameMax, img = Config.Board.ImageMax },
    }
end)

lib.callback.register(script .. ":sv:boardSubmit", function(src, key, meta, form)
    local cfg = Config.Board
    local b = type(key) == "string" and Boards[key]
    if not b then return { ok = false, msg = "ไม่พบจอ" } end
    local pos = ScreenPos(key, meta) or vector3(b.x, b.y, b.z)
    if not Near(src, pos, Config.InteractDistance + 6.0) then return { ok = false, msg = "อยู่ไกลจอเกินไป" } end
    if type(form) ~= "table" then return { ok = false, msg = "ข้อมูลไม่ถูกต้อง" } end

    --@ ตรวจฟอร์ม
    local img = Shared.Clean(form.img, cfg.ImageMax)
    if not img or img == "" or not img:match("^https://[%w%.%-]+/") or img:find("[\"'<>%s]") then
        return { ok = false, msg = "ลิงก์รูปต้องเป็น https:// และยาวไม่เกิน " .. cfg.ImageMax .. " ตัว" }
    end
    if img:lower():find("^data:") or img:lower():find("base64") then return { ok = false, msg = "ห้ามใช้รูป base64" } end
    local text = Shared.Clean(form.text, cfg.TextMax)
    if not text then return { ok = false, msg = "ข้อความยาวเกิน " .. cfg.TextMax .. " ตัว" } end
    local ig, fb, tt = Shared.CleanHandle(form.ig, cfg.NameMax), Shared.CleanHandle(form.fb, cfg.NameMax), Shared.CleanHandle(form.tt, cfg.NameMax)
    if not ig or not fb or not tt then return { ok = false, msg = "ชื่อ IG/FB/TikTok ไม่ถูกต้อง หรือยาวเกิน " .. cfg.NameMax .. " ตัว" } end
    if ig == "" and fb == "" and tt == "" then return { ok = false, msg = "ใส่ IG / FB / TikTok อย่างน้อย 1 ช่อง" } end
    local low = (text .. " " .. img):lower()
    for _, w in ipairs(Config.TV.BlockedWords or {}) do
        if low:find(w:lower(), 1, true) then return { ok = false, msg = "มีคำที่ไม่อนุญาต" } end
    end

    local xPlayer = GetX(src)
    if not xPlayer then return { ok = false } end
    local ident = xPlayer.identifier

    local mine, total = 0, 0
    for _, p in pairs(Pending) do
        total = total + 1
        if p.ident == ident then mine = mine + 1 end
    end
    if mine >= cfg.MaxPendingPerPlayer then return { ok = false, msg = "คุณมีโพสต์รออนุมัติอยู่แล้ว" } end
    if total >= cfg.MaxPendingTotal then return { ok = false, msg = "คิวรออนุมัติเต็ม ลองใหม่ภายหลัง" } end
    if not RateOk(src, "submit", cfg.SubmitCooldown) then return { ok = false, msg = "ส่งถี่เกินไป รอสักครู่" } end

    --@ หักเงินตอนส่ง ถ้าโดนปฏิเสธ/หมดเวลา คืนเต็ม
    local paid = 0
    if cfg.Price > 0 then
        local acc = xPlayer.getAccount(cfg.Account)
        if not acc or acc.money < cfg.Price then return { ok = false, msg = "เงินไม่พอ" } end
        xPlayer.removeAccountMoney(cfg.Account, cfg.Price, "bit_tv:board")
        paid = cfg.Price
    end

    local id = NextPost
    NextPost = NextPost + 1
    local name = NameOf(xPlayer, src)
    Pending[id] = {
        id = id, group = b.group, boardKey = key, src = src, ident = ident, name = name, paid = paid, at = os.time(),
        post = { name = name, img = img, text = text, ig = ig, fb = fb, tt = tt },
    }

    for admin in pairs(Admins) do
        Notify(admin, "info", ("มีวาร์ปรออนุมัติใหม่ (%s) /%s"):format(name, cfg.AdminCommand), 6000)
    end
    Log("submit", src, ("ส่งวาร์ป #%d กลุ่ม `%s`\nรูป: %s\nข้อความ: %s\nIG: %s | FB: %s | TT: %s"):format(id, b.group, img, text, ig, fb, tt))
    return { ok = true, msg = "ส่งแล้ว รอแอดมินอนุมัติ" }
end)

--@ ================================================================================================
--@ แอดมิน
--@ ================================================================================================
local function CleanGroup(g)
    g = Shared.Clean(g, 24)
    if not g or g == "" then return nil end
    if not g:match("^[%w_%-]+$") then return nil end
    return g:lower()
end

local AdminActions = {}

AdminActions.list = function()
    return { ok = true, pending = PendingList(), boards = BoardList(), price = Config.Board.Price }
end

AdminActions.approve = function(src, d)
    local p = Pending[tonumber(d.id)]
    if not p then return { ok = false, msg = "โพสต์นี้ไม่อยู่แล้ว" } end
    if not GroupHasBoard(p.group) then return { ok = false, msg = "กลุ่มจอนี้ถูกลบไปแล้ว ให้กดปฏิเสธเพื่อคืนเงิน" } end
    local q = PruneQueue(p.group)
    if #q >= Config.Board.MaxQueuePerGroup then return { ok = false, msg = "คิวขึ้นจอของกลุ่มนี้เต็ม" } end

    local now = Now()
    local startAt = now + 1.0
    if #q > 0 then startAt = math.max(startAt, q[#q].startAt + Config.Board.Duration) end
    local entry = { id = p.id, post = PostCard(p.post), startAt = startAt }
    q[#q + 1] = entry
    Queue[p.group] = q
    Pending[p.id] = nil

    TriggerClientEvent(script .. ":cl:post", -1, p.group, entry, now)
    local wait = math.floor(startAt - now)
    local owner = p.src and GetX(p.src)
    if owner and owner.identifier == p.ident then
        Notify(p.src, "success", wait > 1 and ("วาร์ปของคุณผ่านแล้ว ขึ้นจอในอีก ~%d วินาที"):format(wait) or "วาร์ปของคุณขึ้นจอแล้ว")
    end
    Log("approve", src, ("อนุมัติวาร์ป #%d ของ %s กลุ่ม `%s`"):format(p.id, p.name, p.group))
    return AdminActions.list()
end

AdminActions.reject = function(src, d)
    local p = Pending[tonumber(d.id)]
    if not p then return { ok = false, msg = "โพสต์นี้ไม่อยู่แล้ว" } end
    Pending[p.id] = nil
    PayBack(p.ident, p.src, p.paid, "วาร์ปไม่ผ่านการอนุมัติ")
    if p.paid <= 0 and p.src and GetX(p.src) then Notify(p.src, "error", "วาร์ปของคุณไม่ผ่านการอนุมัติ") end
    Log("reject", src, ("ปฏิเสธวาร์ป #%d ของ %s"):format(p.id, p.name))
    return AdminActions.list()
end

--@ จอใสลอย
AdminActions.createFree = function(src, d)
    local x, y, z, h, w = tonumber(d.x), tonumber(d.y), tonumber(d.z), tonumber(d.h), tonumber(d.w)
    if not (x and y and z and h and w) then return { ok = false, msg = "ข้อมูลไม่ถูกต้อง" } end
    local group = CleanGroup(d.group)
    if not group then return { ok = false, msg = "ชื่อกลุ่มใช้ได้แค่ a-z 0-9 _ -" } end
    if not Near(src, vector3(x, y, z), 40.0) then return { ok = false, msg = "วางไกลตัวเกินไป" } end
    w = math.max(Config.Board.Free.MinWidth, math.min(Config.Board.Free.MaxWidth, w))
    local key = "f:" .. NextBoard
    NextBoard = NextBoard + 1
    local b = { key = key, group = group, kind = "free", x = x, y = y, z = z, h = h % 360.0, w = w }
    Boards[key] = b
    TriggerClientEvent(script .. ":cl:board", -1, key, b)
    Log("board", src, ("สร้างจอใส `%s` กลุ่ม `%s`"):format(key, group))
    return AdminActions.list()
end

--@ เปลี่ยนทีวีใกล้ตัวเป็นจอวาร์ป
AdminActions.attachTv = function(src, d)
    local key = type(d.key) == "string" and d.key or nil
    if not key or key:sub(1, 1) == "f" then return { ok = false, msg = "ไม่พบทีวีใกล้ตัว" } end
    local pos = ScreenPos(key, d.meta)
    if not pos or not Near(src, pos, 10.0) then return { ok = false, msg = "ไม่พบทีวีใกล้ตัว" } end
    if Boards[key] then return { ok = false, msg = "ทีวีนี้เป็นจอวาร์ปอยู่แล้ว" } end
    local group = CleanGroup(d.group)
    if not group then return { ok = false, msg = "ชื่อกลุ่มใช้ได้แค่ a-z 0-9 _ -" } end
    if Play[key] then SetPlay(key, nil) end
    local b = { key = key, group = group, kind = "tv", x = pos.x, y = pos.y, z = pos.z, model = d.meta and tonumber(d.meta.model) }
    Boards[key] = b
    TriggerClientEvent(script .. ":cl:board", -1, key, b)
    Log("board", src, ("ตั้งทีวี `%s` เป็นจอวาร์ป กลุ่ม `%s`"):format(key, group))
    return AdminActions.list()
end

AdminActions.setGroup = function(src, d)
    local b = Boards[d.key]
    if not b then return { ok = false, msg = "ไม่พบจอ" } end
    local group = CleanGroup(d.group)
    if not group then return { ok = false, msg = "ชื่อกลุ่มใช้ได้แค่ a-z 0-9 _ -" } end
    b.group = group
    TriggerClientEvent(script .. ":cl:board", -1, b.key, b)
    if not Queue[group] then Queue[group] = {} end
    TriggerClientEvent(script .. ":cl:queue", -1, group, PruneQueue(group), Now())
    return AdminActions.list()
end

AdminActions.delete = function(src, d)
    if not Boards[d.key] then return { ok = false, msg = "ไม่พบจอ" } end
    RemoveBoard(d.key)
    Log("board", src, ("ลบจอวาร์ป `%s`"):format(d.key))
    return AdminActions.list()
end

AdminActions.skip = function(src, d)
    local group = CleanGroup(d.group)
    if not group then return { ok = false } end
    Queue[group] = {}
    TriggerClientEvent(script .. ":cl:queue", -1, group, {}, Now())
    Log("board", src, ("ล้างคิวขึ้นจอกลุ่ม `%s`"):format(group))
    return AdminActions.list()
end

lib.callback.register(script .. ":sv:admin", function(src, action, data)
    if not IsAdmin(src) then return { ok = false, msg = "เฉพาะแอดมิน" } end
    local fn = AdminActions[action]
    if not fn then return { ok = false } end
    return fn(src, type(data) == "table" and data or {})
end)

--@ คำขอที่แอดมินไม่กดนานเกิน = ยกเลิก + คืนเงิน
CreateThread(function()
    while true do
        Wait(60000)
        local limit = os.time() - Config.Board.PendingExpireMinutes * 60
        for id, p in pairs(Pending) do
            if p.at < limit then
                Pending[id] = nil
                PayBack(p.ident, p.src, p.paid, "วาร์ปหมดเวลารออนุมัติ")
            end
        end
    end
end)

--@ ================================================================================================
--@ sync ตอนเข้าเกม / รีสคริปต์
--@ ================================================================================================
lib.callback.register(script .. ":sv:sync", function(src)
    IsAdmin(src)
    local play = {}
    for key, st in pairs(Play) do play[key] = PublicPlay(st) end
    local queue = {}
    for group in pairs(Queue) do queue[group] = PruneQueue(group) end
    return { now = Now(), play = play, props = Props, boards = Boards, queue = queue }
end)

AddEventHandler("esx:playerLoaded", function(src, xPlayer)
    if xPlayer and Config.AdminGroups[xPlayer.getGroup()] then Admins[src] = true end
    local ident = xPlayer and xPlayer.identifier
    local amount = ident and Refund[ident]
    if amount and amount > 0 then
        Refund[ident] = nil
        xPlayer.addAccountMoney(Config.Board.Account, amount, "bit_tv:refund")
        SetTimeout(5000, function()
            Notify(src, "info", ("คืนเงินค่าวาร์ปที่ไม่ได้ขึ้นจอ $%s"):format(amount))
        end)
    end
end)

AddEventHandler("playerDropped", function()
    local src = source
    Admins[src] = nil
    RateLast[src] = nil
    for _, p in pairs(Pending) do
        if p.src == src then p.src = nil end
    end
end)

--@ รีสคริปต์ : คืนเงินคนที่ยังรออนุมัติ (ของในคิวหายตอนสคริปต์หยุด)
AddEventHandler("onResourceStop", function(res)
    if res ~= script then return end
    for _, p in pairs(Pending) do
        if p.paid > 0 and p.src then
            local xPlayer = GetX(p.src)
            if xPlayer and xPlayer.identifier == p.ident then
                xPlayer.addAccountMoney(Config.Board.Account, p.paid, "bit_tv:refund")
            end
        end
    end
end)

DebugPrint("started")
