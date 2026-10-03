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
}

Shared.ProviderLabel = {
    youtube = "YouTube",
    twitch = "Twitch",
    twitch_clip = "Twitch Clip",
    facebook = "Facebook",
    tiktok = "TikTok",
    kick = "Kick",
    direct = "Video",
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

local ORDER = { "youtube", "twitch", "facebook", "tiktok", "kick", "direct" }

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
    return nil, "รองรับเฉพาะ YouTube / TikTok / Facebook / Twitch / Kick (ลิงก์เต็ม)"
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
