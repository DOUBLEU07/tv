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
        vol: 60,
        personal: 70,
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
            } else if (mode === 'submit') {
                this.form = { img: '', text: '', ig: '', fb: '', tt: '' };
                this.imgOk = true;
            } else if (mode === 'admin') {
                this.tab = this.d.tab || (this.d.pending && this.d.pending.length ? 'pending' : this.tab);
                this.newWidth = this.d.defaultWidth || 2.4;
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

        // remote
        play: function () {
            if (!this.url) return;
            var self = this;
            this.call('remote', { act: 'play', url: this.url, vol: this.vol }).then(function (res) { if (res.ok) self.url = ''; });
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
                    var tab = self.tab;
                    self.d = Object.assign({}, self.d, { pending: res.pending, boards: res.boards });
                    self.tab = tab;
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
    }
    else if (m.action === 'hint') app.hint = m.lines;
});

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
        remote: { canControl: true, canRemove: true, playing: { provider: 'YouTube', url: 'https://www.youtube.com/watch?v=jfKfPfyJRdk', audio: 'volume', by: 'Somchai' }, vol: 60, personal: 70 },
        submit: { group: 'bar_a', price: 5000, queue: 2, wait: 24, duration: 15, limits: { text: 80, name: 30, img: 600 } },
        admin: { pending: [{ id: 1, group: 'bar_a', name: 'Somchai', paid: 5000, post: post1 }, { id: 2, group: 'club', name: 'Nida', paid: 0, post: { img: 'https://picsum.photos/401', text: '', ig: '', fb: '', tt: 'nida.dance' } }],
                 boards: [{ key: 'f:1', group: 'bar_a', kind: 'free', x: 120.5, y: -1290.2, z: 29.3, queue: 2 }, { key: 'm:12345:1.0:2.0:3.0', group: 'bar_a', kind: 'tv', x: 1, y: 2, z: 3, queue: 2 }], defaultWidth: 2.4 },
        place: { models: [{ model: 'prop_tv_flat_01', label: 'ทีวีจอแบน 1' }, { model: 'prop_tv_flat_02', label: 'ทีวีจอแบน 2' }, { model: 'prop_tv_flat_michael', label: 'ทีวีจอใหญ่' }, { model: 'prop_huge_display_01', label: 'จอยักษ์' }] }
    };
    if (demo === 'hint') { app.hint = ['<b>วางจอใส</b> กลุ่ม: bar_a', 'เมาส์ = เล็งตำแหน่ง', 'ลูกกลิ้ง = หมุน (Shift = ละเอียด)', '↑ ↓ = ยก/ลด   ← → = ขนาด', 'Enter = วาง   Backspace = ยกเลิก']; return; }
    if (data[demo]) app.open(demo, data[demo]);
    if (demo === 'submit') { app.form = { img: 'https://picsum.photos/400', text: 'ร้านเหล้าเปิดแล้ว มาดื่มกันคืนนี้!', ig: 'somchai.bit', fb: '', tt: 'somchai_tt' }; }
})();
