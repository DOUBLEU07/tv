fx_version "cerulean"
game "gta5"
lua54 "yes"

description "BIT TV - ทีวีเปิดลิงก์ (YouTube/TikTok/Facebook/Twitch/Kick) + จอโชว์วาร์ป"

shared_scripts {
    "@ox_lib/init.lua",
    "config.lua",
    "shared.lua",
}

server_scripts {
    "server.lua",
}

client_scripts {
    "client/main.lua",
    "client/render.lua",
    "client/place.lua",
}

ui_page "web/index.html"

files {
    "web/**",
}

dependencies {
    "es_extended",
    "ox_lib",
}
