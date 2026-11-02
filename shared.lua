Shared = {}

--@ ================================================================================================
--@ แปลงลิงก์ -> media (ใช้ทั้ง client/server เซิร์ฟเป็นคนตัดสินจริง)
--@ ไวท์ลิสต์ : ผ่านเฉพาะลิงก์ที่แกะรูปแบบได้ของเว็บที่เปิดใน Config.TV.Providers
--@ ================================================================================================

--@ ความสามารถคุมเสียงของแต่ละเว็บ : "volume" ปรับละเอียด / "mute" เปิด-ปิด / false คุมไม่ได้
Shared.AudioControl = {
    youtube = "volume",
    twitch = "volume",
    twitch_clip = false,
    facebook = "volume",
    tiktok = "mute",
    kick = false,
    direct = "volume",
    image = "none",     --@ ไม่มีเสียง : วาดถึง Render.Distance เหมือนเว็บที่คุมเสียงได้
}

--@ กรอเวลาได้ (ไลฟ์ / TikTok / Kick / Twitch clip กรอไม่ได้)
local SEEKABLE = { youtube = true, twitch = true, facebook = true, direct = true }
function Shared.CanSeek(media)
    return media ~= nil and SEEKABLE[media.p] == true and not media.live
end

Shared.ProviderLabel = {
    youtube = "YouTube",
    twitch = "Twitch",
    twitch_clip = "Twitch Clip",
    facebook = "Facebook",
    tiktok = "TikTok",
    kick = "Kick",
    direct = "Video",
    image = "รูปภาพ",
}

local function Query(url, key)
    return url:match("[%?&]" .. key .. "=([^&#]+)")
end

--@ "90" / "90s" / "1m30s" / "1h2m3s" -> วินาที
local function ParseTime(t)
    if not t then return 0 end
    if t:match("^%d+$") then return tonumber(t) end
    local h = tonumber(t:match("(%d+)h")) or 0
    local m = tonumber(t:match("(%d+)m")) or 0
    local s = tonumber(t:match("(%d+)s")) or 0
    return h * 3600 + m * 60 + s
end

local function HostOf(url)
    local host = url:match("^https?://([^/%?#:]+)")
    if not host then return nil end
    host = host:lower()
    host = host:gsub("^www%.", ""):gsub("^m%.", ""):gsub("^mobile%.", ""):gsub("^web%.", "")
    return host
end

local function PathOf(url)
    return url:match("^https?://[^/%?#]+(/[^%?#]*)") or "/"
end

local function IsYtId(id)
    return id and #id == 11 and id:match("^[%w_%-]+$") ~= nil
end

local TWITCH_RESERVED = { directory = true, videos = true, p = true, settings = true, subscriptions = true, inventory = true, wallet = true, search = true, downloads = true, jobs = true, turbo = true, friends = true }
local KICK_RESERVED = { video = true, categories = true, browse = true, following = true, search = true, dashboard = true, settings = true, terms = true, privacy = true, community = true }

local Parsers = {}

Parsers.youtube = function(url, host, path)
    if host ~= "youtube.com" and host ~= "youtu.be" and host ~= "music.youtube.com" and host ~= "youtube-nocookie.com" then return nil end
    local id
    if host == "youtu.be" then
        id = path:match("^/([%w_%-]+)")
    else
        id = Query(url, "v") or path:match("^/shorts/([%w_%-]+)") or path:match("^/live/([%w_%-]+)") or path:match("^/embed/([%w_%-]+)")
    end
    if not IsYtId(id) then return nil end
    return { p = "youtube", id = id, s = ParseTime(Query(url, "t") or Query(url, "start")) }
end

Parsers.twitch = function(url, host, path)
    if host == "clips.twitch.tv" then
        local slug = path:match("^/([%w_%-]+)$")
        if slug and slug ~= "embed" then return { p = "twitch_clip", id = slug } end
        return nil
    end
    if host ~= "twitch.tv" then return nil end
    local vod = path:match("^/videos/(%d+)")
    if vod then return { p = "twitch", v = vod, s = ParseTime(Query(url, "t")) } end
    local clip = path:match("^/[%w_]+/clip/([%w_%-]+)")
    if clip then return { p = "twitch_clip", id = clip } end
    local ch = path:match("^/([%w_]+)/?$")
    if ch and not TWITCH_RESERVED[ch:lower()] then return { p = "twitch", ch = ch:lower(), live = true } end
    return nil
end

Parsers.facebook = function(url, host, path)
    if host == "fb.watch" then
        local code = path:match("^/([%w_%-]+)")
        if code then return { p = "facebook", href = "https://fb.watch/" .. code .. "/" } end
        return nil
    end
    if host ~= "facebook.com" then return nil end
    local ok = path:match("/videos/") or path:match("^/watch") or path:match("^/reel/%d+") or path:match("^/share/[vr]/") or path:match("^/[^/]+/live")
    if not ok then return nil end
    local href = "https://www.facebook.com" .. path
    local v = Query(url, "v")
    if path:match("^/watch") then
        if not (v and v:match("^%d+$")) then return nil end
        href = "https://www.facebook.com/watch/?v=" .. v
    end
    if href:find("[\"'<>%s]") then return nil end
    return { p = "facebook", href = href, s = ParseTime(Query(url, "t")) }
end

Parsers.tiktok = function(url, host, path)
    if host ~= "tiktok.com" then return nil end
    local id = path:match("^/@[^/]+/video/(%d+)") or path:match("^/embed/v2/(%d+)") or path:match("^/player/v1/(%d+)")
    if not id then return nil end
    return { p = "tiktok", id = id }
end

Parsers.kick = function(url, host, path)
    if host ~= "kick.com" and host ~= "player.kick.com" then return nil end
    local ch = path:match("^/([%w_%-]+)/?$")
    if not ch or KICK_RESERVED[ch:lower()] then return nil end
    return { p = "kick", ch = ch:lower(), live = true }
end

Parsers.direct = function(url, host, path)
    local ext = path:lower():match("%.(%w+)$")
    if ext ~= "mp4" and ext ~= "webm" and ext ~= "m3u8" then return nil end
    for _, d in ipairs(Config.TV.DirectDomains or {}) do
        d = d:lower()
        if host == d or host:sub(-(#d + 1)) == "." .. d then
            if url:find("[\"'<>%s]") then return nil end
            return { p = "direct", src = url, hls = ext == "m3u8" }
        end
    end
    return nil
end

--@ ลิงก์รูปตรงๆ : https เท่านั้น (จออยู่บน https ลิงก์ http โดนบล็อก) + นามสกุลรูปท้าย path (query แบบ discord ?ex= ได้)
local IMAGE_EXT = { jpg = true, jpeg = true, png = true, gif = true, webp = true }
Parsers.image = function(url, host, path)
    if not url:match("^https://") then return nil end
    local ext = path:lower():match("%.(%w+)$")
    if not ext or not IMAGE_EXT[ext] then return nil end
    if url:find("[\"'<>%s\\]") then return nil end
    local list = Config.TV.ImageDomains or {}
    if #list == 0 then return { p = "image", src = url } end
    for _, d in ipairs(list) do
        d = d:lower()
        if host == d or host:sub(-(#d + 1)) == "." .. d then return { p = "image", src = url } end
    end
    return nil
end

local ORDER = { "youtube", "twitch", "facebook", "tiktok", "kick", "direct", "image" }

--@ return media | nil, ข้อความ error
function Shared.ParseMedia(url)
    if type(url) ~= "string" then return nil, "ลิงก์ไม่ถูกต้อง" end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if #url < 8 or #url > 500 then return nil, "ลิงก์ยาว/สั้นผิดปกติ" end
    if not url:match("^https?://") then url = "https://" .. url end

    local low = url:lower()
    for _, w in ipairs(Config.TV.BlockedWords or {}) do
        if low:find(w:lower(), 1, true) then return nil, "ลิงก์นี้ไม่อนุญาต" end
    end

    local host = HostOf(url)
    if not host then return nil, "ลิงก์ไม่ถูกต้อง" end
    local path = PathOf(url)
    if host == "vm.tiktok.com" or host == "vt.tiktok.com" then
        return nil, "ลิงก์ย่อ TikTok ใช้ไม่ได้ เปิดคลิปในเบราว์เซอร์แล้วก๊อปลิงก์เต็ม (tiktok.com/@ชื่อ/video/เลข)"
    end

    for _, name in ipairs(ORDER) do
        if Config.TV.Providers[name] then
            local m = Parsers[name](url, host, path)
            if m then
                m.url = url
                return m
            end
        end
    end
    if Config.TV.Providers.image and IMAGE_EXT[(path:lower():match("%.(%w+)$") or "")] then
        return nil, "ลิงก์รูปนี้ใช้ไม่ได้ (ต้องเป็น https และอยู่ในเว็บที่อนุญาต)"
    end
    return nil, Config.TV.Providers.image and "รองรับเฉพาะ YouTube / TikTok / Facebook / Twitch / Kick / ลิงก์รูป (ลิงก์เต็ม)"
        or "รองรับเฉพาะ YouTube / TikTok / Facebook / Twitch / Kick (ลิงก์เต็ม)"
end

--@ ================================================================================================
--@ ตัวช่วยอื่น
--@ ================================================================================================
function Shared.Utf8Len(s)
    local ok, n = pcall(utf8.len, s)
    return ok and n or #s
end

--@ ตัดอักขระควบคุม + ช่องว่างหัวท้าย
function Shared.Clean(s, maxLen)
    if type(s) ~= "string" then return "" end
    s = s:gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if maxLen and Shared.Utf8Len(s) > maxLen then return nil end
    return s
end

--@ ชื่อ IG/FB/TikTok : ตัด @ และลิงก์เต็มให้เหลือชื่อ
function Shared.CleanHandle(s, maxLen)
    s = Shared.Clean(s, 200)
    if not s or s == "" then return "" end
    s = s:gsub("^https?://", ""):gsub("^www%.", "")
    s = s:gsub("^instagram%.com/", ""):gsub("^facebook%.com/", ""):gsub("^tiktok%.com/", "")
    s = s:gsub("^@", ""):gsub("[/%?#].*$", "")
    if not s:match("^[%w%._%-]+$") then
        --@ FB ใช้ชื่อไทย/เว้นวรรคได้ ยอมให้ผ่านถ้าไม่มีอักขระแปลก
        if s:find("[<>\"'`]") then return nil end
    end
    if Shared.Utf8Len(s) > maxLen then return nil end
    return s
end

--@ hash แบบไม่ติดลบ (client GetEntityModel กับ GetHashKey บางทีได้เลขติดลบ/ไม่ติดลบต่างกัน)
function Shared.ModelHash(m)
    local h = type(m) == "number" and m or GetHashKey(m)
    return math.floor(h) % 4294967296
end

--@ key ของทีวีในแมพ = รุ่น + พิกัด (ทศนิยม 1 ตำแหน่ง) ทุกเครื่องได้ค่าเดียวกัน
function Shared.MapKey(model, x, y, z)
    return ("m:%d:%.1f:%.1f:%.1f"):format(Shared.ModelHash(model), x, y, z)
end

--@ รุ่นทีวีที่รองรับ [hash] = ข้อมูลจาก Config.TV.Models
Shared.Models = {}
for _, m in ipairs(Config.TV.Models) do
    Shared.Models[Shared.ModelHash(m.model)] = m
end
--@ รุ่นที่ให้วาง (/tvplace) ต้องเป็นทีวีด้วยเสมอ ไม่งั้นวางแล้วกด E / Alt+คลิก / หาใน /tvadmin ไม่เจอ
for _, m in ipairs(Config.TV.Place.Models) do
    local h = Shared.ModelHash(m.model)
    if not Shared.Models[h] then Shared.Models[h] = { model = m.model } end
end

--@ ================================================================================================
--@ จอแผ่นจาก Config.Screens : [key "c:<id>"] = { key, id, mode, x, y, z, h, w, ht, fit, admin, idle, range, group }
--@ client/server สร้างจาก config ชุดเดียวกัน เลยได้ค่าตรงกันโดยไม่ต้องส่งข้ามกัน
--@ ================================================================================================
Shared.Screens = {}

local FITS = { contain = true, cover = true, stretch = true }

local function IdleColor(v)
    if v == false then return false end
    if type(v) == "table" then return v end
    return Config.ScreenIdleColor or { 6, 8, 12, 235 }
end

for i, s in ipairs(Config.Screens or {}) do
    local id = type(s.id) == "string" and s.id:lower() or nil
    local c = s.coords
    local w, ht = tonumber(s.width), tonumber(s.height)
    local bad = not id or not id:match("^[%w_%-]+$") or not c or not w or not ht or w <= 0 or ht <= 0
        or (s.mode ~= "tv" and s.mode ~= "warp")
    if bad then
        print(("^1[bit_tv] Config.Screens[%d] ไม่ถูกต้อง (ต้องมี id, mode = \"tv\"/\"warp\", coords, width, height)^0"):format(i))
    elseif Shared.Screens["c:" .. id] then
        print(("^1[bit_tv] Config.Screens id \"%s\" ซ้ำ^0"):format(id))
    else
        local key = "c:" .. id
        local group = type(s.group) == "string" and s.group:lower():match("^[%w_%-]+$") and s.group:lower() or id
        Shared.Screens[key] = {
            key = key,
            id = id,
            mode = s.mode,
            x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0,
            h = (tonumber(s.heading) or 0.0) % 360.0,
            w = w + 0.0,
            ht = ht + 0.0,
            fit = FITS[s.fit] and s.fit or "contain",
            admin = s.admin ~= false,
            idle = IdleColor(s.idle),
            range = tonumber(s.range) or ((Config.Click and Config.Click.Distance or 8.0) + math.max(w, ht) * 0.5),
            group = group,
        }
    end
end
