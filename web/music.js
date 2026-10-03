// =========================================================================================
// โหมดเพลง : เล่นเสียง YouTube ในหน้า UI หลักของสคริปต์ (ui_page) แบบ nc_musicplayers
// ไม่ได้เล่นใน DUI ของจอ (DUI โดนโฆษณา, หน้า UI หลักไม่โดน — ผู้ใช้ทดสอบในเกม 2026-10-04)
// render.lua ส่ง { action: 'music', key, rev, id, elapsed, vol, seek } ทุก 250ms ต่อทีวีที่อยู่ในระยะเสียง
// ออกนอกระยะ = { action: 'musicStop', key }
// ชื่อเพลง/ความยาวส่งกลับทาง NUI callback musicInfo ให้จอทีวีโชว์
// =========================================================================================
(function () {
    var RES = typeof window.GetParentResourceName === 'function' ? GetParentResourceName() : 'bit_tv';
    var players = {};   // [key] = player
    var apiReady = null;

    function loadApi() {
        if (apiReady) return apiReady;
        apiReady = new Promise(function (resolve) {
            if (window.YT && window.YT.Player) return resolve();
            var prev = window.onYouTubeIframeAPIReady;
            window.onYouTubeIframeAPIReady = function () { if (prev) prev(); resolve(); };
            var s = document.createElement('script');
            s.src = 'https://www.youtube.com/iframe_api';
            document.head.appendChild(s);
        });
        return apiReady;
    }

    function send(p, info) {
        fetch('https://' + RES + '/musicInfo', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(Object.assign({ rev: p.rev }, info))
        }).catch(function () {});
    }

    // ส่งชื่อ + ความยาวครั้งเดียว (ไลฟ์ไม่มีความยาว : รอ 8 วิแล้วส่งแค่ชื่อ)
    function report(p) {
        if (p.reported || !p.ready) return;
        var vd = (p.yt.getVideoData && p.yt.getVideoData()) || {};
        var d = p.yt.getDuration() || 0;
        if (!vd.title) return;
        if (!(d > 0) && Date.now() - p.created < 8000) return;
        p.reported = true;
        send(p, { title: vd.title, author: vd.author || '', d: Math.floor(d) });
    }

    function create(d) {
        var p = { key: d.key, rev: d.rev, yt: null, ready: false, vol: d.vol || 0, seek: d.seek || 0,
                  lastDrift: Date.now(), created: Date.now(), reported: false, dead: false };
        // กล่อง 0x0 มองไม่เห็น เหมือน nc_musicplayers
        p.box = document.createElement('div');
        p.box.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;overflow:hidden;pointer-events:none;';
        var div = document.createElement('div');
        p.box.appendChild(div);
        document.body.appendChild(p.box);

        loadApi().then(function () {
            if (p.dead) return;
            p.yt = new YT.Player(div, {
                width: 0, height: 0, videoId: d.id,
                playerVars: { autoplay: 1, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, rel: 0, playsinline: 1, start: Math.floor(d.elapsed || 0) },
                events: {
                    onReady: function (e) {
                        p.ready = true;
                        e.target.unMute();
                        e.target.setVolume(p.vol);
                        e.target.playVideo();
                    },
                    onError: function (e) {
                        if (p.reported) return;
                        p.reported = true;
                        var c = e.data;
                        send(p, { title: 'เล่นเพลงนี้ไม่ได้', author: (c === 101 || c === 150) ? 'เจ้าของคลิปไม่อนุญาตให้เล่นนอก YouTube' : 'YouTube error ' + c, d: 0, error: true });
                    }
                }
            });
        });
        return p;
    }

    function destroy(p) {
        p.dead = true;
        try { if (p.yt && p.yt.destroy) p.yt.destroy(); } catch (e) {}
        if (p.box && p.box.parentNode) p.box.parentNode.removeChild(p.box);
    }

    function update(p, d) {
        p.vol = d.vol || 0;
        if (!p.ready) return;
        try {
            p.yt.setVolume(p.vol);
            if (p.vol > 0) p.yt.unMute(); else p.yt.mute();
            // มีคนกดกรอ = กรอทันที ; ปกติเช็คเวลาเพี้ยนทุก 3 วิ
            var forced = (d.seek || 0) !== p.seek;
            if (forced || Date.now() - p.lastDrift > 3000) {
                p.lastDrift = Date.now();
                p.seek = d.seek || 0;
                var dur = p.yt.getDuration() || 0;
                var el = d.elapsed || 0;
                if (dur > 0 && el < dur && (forced || Math.abs(p.yt.getCurrentTime() - el) > 4)) {
                    p.yt.seekTo(el, true);
                    p.yt.playVideo();
                }
            }
            report(p);
        } catch (e) {}
    }

    window.addEventListener('message', function (e) {
        var d = e.data || {};
        if (d.action === 'music') {
            var p = players[d.key];
            if (p && p.rev !== d.rev) { destroy(p); p = null; }
            if (!p) players[d.key] = create(d);
            else update(p, d);
        } else if (d.action === 'musicStop') {
            if (players[d.key]) { destroy(players[d.key]); delete players[d.key]; }
        }
    });
})();
