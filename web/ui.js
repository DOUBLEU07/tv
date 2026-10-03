var IS_GAME = typeof window.GetParentResourceName === 'function';
var RES = IS_GAME ? GetParentResourceName() : 'bit_tv';

function post(endpoint, data) {
    if (!IS_GAME) return Promise.resolve({ ok: true });
    return fetch('https://' + RES + '/' + endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {})
    }).then(function (r) { return r.json(); }).catch(function () { return { ok: false }; });
}

var sounds = {};
function playSound(name, volume) {
    try {
        var a = sounds[name];
        if (!a) { a = new Audio('sound/' + name + '.wav'); sounds[name] = a; }
        a.volume = volume;
        a.currentTime = 0;
        a.play().catch(function () {});
    } catch (e) {}
}

var app = new Vue({
    el: '#app',
    data: {
        visible: false,
        mode: null,
        d: {},
        busy: false,
        hint: null,
        // remote
        url: '',
        music: false,
        vol: 60,
        personal: 70,
        pos: 0,
        posBase: 0,
        posAt: 0,
        dragging: false,
        slideVal: 0,
        seekTimer: null,
        seekDelaySec: 1.2,
        // submit
        form: { img: '', text: '', ig: '', fb: '', tt: '' },
        imgOk: true,
        // admin
        tab: 'pending',
        newGroup: '',
        newWidth: 2.4,
        editGroup: {}
    },
    computed: {
        headIcon: function () {
            return { remote: 'mdi:television-play', submit: 'mdi:card-account-details-star', admin: 'mdi:shield-account', place: 'mdi:television-classic' }[this.mode] || 'mdi:television';
        },
        headTitle: function () {
            return { remote: 'TV', submit: 'ลงวาร์ป', admin: 'TV ADMIN', place: 'วางทีวี' }[this.mode] || 'TV';
        },
        headSub: function () {
            if (this.mode === 'remote') return 'เปิดลิงก์ให้ทุกคนรอบๆ ดูพร้อมกัน';
            if (this.mode === 'submit') return 'กลุ่มจอ #' + (this.d.group || '');
            if (this.mode === 'admin') return 'อนุมัติวาร์ป • จัดการจอ';
            if (this.mode === 'place') return 'เลือกรุ่น แล้วเล็งตำแหน่งที่จะวาง';
            return '';
        },
        shownPos: function () {
            var p = this.dragging ? this.slideVal : this.pos;
            return Math.min(Math.floor(p), this.seekMax);
        },
        // ไม่รู้ความยาว = เผื่อไปข้างหน้า 10 นาที
        seekMax: function () {
            var p = this.d.playing;
            if (p && p.duration) return Math.max(1, Math.floor(p.duration));
            return Math.max(600, Math.ceil((this.pos + 600) / 60) * 60);
        },
        canSubmit: function () {
            var f = this.form;
            return /^https:\/\//i.test(f.img) && (f.ig || f.fb || f.tt);
        }
    },
    methods: {
        hover: function () { playSound('hover', 0.1); },
        len: function (s) { return Array.from(s || '').length; },
        money: function (n) { return '$' + Number(n || 0).toLocaleString('en-US'); },
        groupOk: function (g) { return !!g && /^[A-Za-z0-9_-]{1,24}$/.test(g); },

        open: function (mode, data) {
            this.mode = mode;
            this.d = data || {};
            this.busy = false;
            if (mode === 'remote') {
                this.url = '';
                this.vol = this.d.vol != null ? this.d.vol : 60;
                this.personal = this.d.personal != null ? this.d.personal : 70;
                this.dragging = false;
                clearTimeout(this.seekTimer);
                this.syncPos();
            } else if (mode === 'submit') {
                this.form = { img: '', text: '', ig: '', fb: '', tt: '' };
                this.imgOk = true;
            } else if (mode === 'admin') {
                this.tab = this.d.tab || (this.d.pending && this.d.pending.length ? 'pending' : this.tab);
                this.newWidth = this.d.defaultWidth || 2.4;
                // ชื่อกลุ่มเริ่มต้น = กลุ่มใหม่ที่ยังไม่มีใครใช้ (warp1, warp2, ...)
                if (!this.groupOk(this.newGroup)) {
                    var used = {}, n = 1;
                    (this.d.boards || []).forEach(function (b) { used[b.group] = true; });
                    while (used['warp' + n]) n++;
                    this.newGroup = 'warp' + n;
                }
                this.editGroup = {};
            }
            this.visible = true;
            playSound('open', 0.3);
        },
        close: function () {
            if (!this.visible) return;
            this.visible = false;
            playSound('close', 0.3);
            post('close');
        },
        setTab: function (t) { this.tab = t; playSound('click', 0.25); },

        call: function (endpoint, data) {
            var self = this;
            self.busy = true;
            return post(endpoint, data).then(function (res) {
                self.busy = false;
                playSound(res && res.ok ? 'success' : 'error', 0.3);
                return res || {};
            });
        },

        // remote : เวลาคลิปเดินเองฝั่ง UI จาก elapsed ที่เซิร์ฟให้มา
        syncPos: function () {
            var p = this.d.playing;
            this.posBase = p ? (p.elapsed || 0) : 0;
            this.posAt = Date.now();
            this.pos = this.posBase;
        },
        tickPos: function () {
            if (this.visible && this.mode === 'remote' && this.d.playing) this.pos = this.posBase + (Date.now() - this.posAt) / 1000;
        },
        clock: function (s) {
            s = Math.max(0, Math.floor(s || 0));
            var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
            var mm = (h > 0 && m < 10 ? '0' : '') + m, ss = (x < 10 ? '0' : '') + x;
            return (h > 0 ? h + ':' : '') + mm + ':' + ss;
        },
        // แถบเลื่อน : ลากได้เรื่อยๆ ส่งค่าตอนหยุดนิ่ง seekDelaySec วิ
        onSlide: function (v) {
            var self = this;
            this.dragging = true;
            this.slideVal = Number(v);
            clearTimeout(this.seekTimer);
            this.seekTimer = setTimeout(function () { self.commitSeek(self.slideVal); }, this.seekDelaySec * 1000);
        },
        commitSeek: function (sec) {
            var self = this;
            clearTimeout(this.seekTimer);
            this.call('remote', { act: 'seek', pos: Math.max(0, sec) }).then(function (res) {
                if (res.ok) { self.posBase = Math.max(0, sec); self.posAt = Date.now(); self.pos = self.posBase; }
                self.dragging = false;
            });
        },
        seekBy: function (d) { this.commitSeek(Math.floor((this.dragging ? this.slideVal : this.pos) + d)); },
        touch: function () { post('remote', { act: 'touch' }); this.visible = false; },
        play: function () {
            if (!this.url) return;
            var self = this;
            // ลิงก์ music.youtube.com = เปิดเป็นเพลงให้เลย
            var music = this.music || /music\.youtube\.com/i.test(this.url);
            this.call('remote', { act: 'play', url: this.url, vol: this.vol, music: music }).then(function (res) { if (res.ok) self.url = ''; });
        },
        stop: function () { this.call('remote', { act: 'stop' }); },
        setVol: function () { this.call('remote', { act: 'volume', vol: this.vol }); },
        setPersonal: function () { post('remote', { act: 'personal', vol: this.personal }); playSound('click', 0.25); },
        remove: function () { this.call('remote', { act: 'remove' }); },

        // submit
        submit: function () { this.call('submit', this.form); },

        // admin
        admin: function (act, payload) {
            var self = this;
            this.call('admin', { act: act, payload: payload }).then(function (res) {
                if (res.ok && res.pending) {
                    self.d = Object.assign({}, self.d, { pending: res.pending, boards: res.boards });
                }
                if (res.ok && res.nearby) {
                    self.d = Object.assign({}, self.d, { nearby: res.nearby });
                }
            });
        },

        // place
        place: function (model) { post('place', { model: model }); this.visible = false; }
    }
});

window.addEventListener('message', function (e) {
    var m = e.data || {};
    if (m.action === 'open') app.open(m.mode, m.data);
    else if (m.action === 'close') app.visible = false;
    else if (m.action === 'update') {
        app.d = m.data;
        app.vol = m.data.vol != null ? m.data.vol : app.vol;
        if (!app.dragging) app.syncPos();
    }
    else if (m.action === 'hint') app.hint = m.lines;
});

setInterval(function () { app.tickPos(); }, 500);

window.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && app.visible) app.close();
});

// ดูในเบราว์เซอร์ : index.html?demo=remote | submit | admin | place
(function () {
    if (IS_GAME) return;
    var demo = (location.search.match(/demo=(\w+)/) || [])[1];
    document.body.style.background = '#2b3240 url(https://picsum.photos/1600/900?blur=3) center/cover';
    var post1 = { img: 'https://picsum.photos/400', text: 'ร้านเหล้าเปิดแล้ว มาดื่มกันคืนนี้!', ig: 'somchai.bit', fb: 'Somchai Jaidee', tt: '' };
    var data = {
        remote: { canControl: true, canRemove: true, playing: { provider: 'YouTube', url: 'https://www.youtube.com/watch?v=jfKfPfyJRdk', audio: 'volume', by: 'Somchai', canSeek: true, elapsed: 83, duration: 212 }, vol: 60, personal: 70 },
        submit: { group: 'bar_a', price: 5000, queue: 2, wait: 24, duration: 15, limits: { text: 80, name: 30, img: 600 } },
        admin: { pending: [{ id: 1, group: 'bar_a', name: 'Somchai', paid: 5000, post: post1 }, { id: 2, group: 'club', name: 'Nida', paid: 0, post: { img: 'https://picsum.photos/401', text: '', ig: '', fb: '', tt: 'nida.dance' } }],
                 boards: [{ key: 'f:1', group: 'bar_a', kind: 'free', x: 120.5, y: -1290.2, z: 29.3, queue: 2 }, { key: 'm:12345:1.0:2.0:3.0', group: 'bar_a', kind: 'tv', x: 1, y: 2, z: 3, queue: 2 }], defaultWidth: 2.4,
                 adminRange: 25, tab: (location.search.match(/tab=(\w+)/) || [])[1],
                 nearby: [{ key: 'm:1', model: 'apa_mp_h_str_avunitl_01_b', dist: 2.3, provider: 'YouTube', by: 'Somchai', url: 'https://www.youtube.com/watch?v=jfKfPfyJRdk' },
                          { key: 'p:4', model: 'prop_tv_flat_01', dist: 8.1, placed: true },
                          { key: 'm:2', model: 'prop_tv_flat_michael', dist: 14.6, board: 'bar_a' }] },
        place: { models: [{ model: 'prop_tv_flat_01', label: 'ทีวีจอแบน 1' }, { model: 'prop_tv_flat_02', label: 'ทีวีจอแบน 2' }, { model: 'prop_tv_flat_michael', label: 'ทีวีจอใหญ่' }, { model: 'prop_huge_display_01', label: 'จอยักษ์' }] }
    };
    if (demo === 'hint') { app.hint = ['<b>วางจอใส</b> กลุ่ม: bar_a', 'เมาส์ = เล็งตำแหน่ง', 'ลูกกลิ้ง = หมุน (Shift = ละเอียด)', '↑ ↓ = ยก/ลด   ← → = ขนาด', 'Enter = วาง   Backspace = ยกเลิก']; return; }
    if (data[demo]) app.open(demo, data[demo]);
    if (demo === 'submit') { app.form = { img: 'https://picsum.photos/400', text: 'ร้านเหล้าเปิดแล้ว มาดื่มกันคืนนี้!', ig: 'somchai.bit', fb: '', tt: 'somchai_tt' }; }
})();
