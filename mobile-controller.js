// ttyd Mobile Controller — v2
// Fixed: CSS class/id mismatch, enter sends, no-zoom, always-visible arrows, 1-finger scroll, no ~ spam.

(function () {
    'use strict';

    const SEND_DELAY_MS = 200;
    const isMobile = () => window.matchMedia('(pointer: coarse)').matches;

    const boot = new MutationObserver((_, obs) => {
        const container = document.querySelector('#terminal-container');
        if (container && (window.term || window.socket)) {
            obs.disconnect();
            initClipboard(container);
            initShiftEnter();
            if (isMobile()) initMobile(container);
        }
    });
    boot.observe(document.body, { childList: true, subtree: true });

    // ── Core send ──────────────────────────────────────────────────────────────
    function sendData(seq) {
        const enc = new TextEncoder();
        if (window.socket?.readyState === 1) window.socket.send(enc.encode(seq));
        else if (window.term?.input)         window.term.input(seq);
    }

    // ── Clipboard ──────────────────────────────────────────────────────────────
    // tmux has set-clipboard on → sends OSC 52 on copy. xterm.js's default
    // handler calls writeText outside a gesture frame (silent fail). We register
    // our own handler via term.parser (proposed API, enabled by ttyd's
    // allowProposedApi:true) to intercept OSC 52 and write to clipboard.
    function initClipboard(container) {
        // Right-click → browser's native context menu. With tmux mouse on, xterm.js
        // forwards the right button to the app and suppresses the menu; capture
        // before xterm.js (don't preventDefault) so the browser's own menu shows.
        container.addEventListener('mousedown', e => {
            if (e.button === 2) e.stopImmediatePropagation();
        }, { capture: true });
        container.addEventListener('contextmenu', e => {
            e.stopImmediatePropagation();
        }, { capture: true });
        const setup = () => {
            if (!window.term?.parser) { setTimeout(setup, 200); return; }
            try {
                window.term.parser.registerOscHandler(52, (data) => {
                    // data = "Pc;Pd" e.g. "c;SGVsbG8="
                    const semi = data.indexOf(';');
                    if (semi < 0) return false;
                    const b64 = data.slice(semi + 1);
                    if (!b64 || b64 === '?') return false;
                    try {
                        const text = atob(b64);
                        navigator.clipboard.writeText(text).catch(() => {});
                    } catch {}
                    return false; // let xterm also handle it
                });
            } catch (e) {
                console.error('[clip] registerOscHandler unavailable:', e);
            }
        };
        setup();
    }

    // ── Shift+Enter → Ctrl+J (chat:newline) without submitting ────────────────
    // Capture phase runs before xterm.js; stopImmediatePropagation prevents
    // xterm.js from also processing Enter and sending \r (which would submit).
    function initShiftEnter() {
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && e.shiftKey) {
                e.preventDefault();
                e.stopImmediatePropagation();
                sendData('\x0a');
            }
        }, true);
    }

    // ── Mobile UI ──────────────────────────────────────────────────────────────
    function initMobile(container) {
        // Prevent iOS auto-zoom on input focus (triggered when font-size < 16px)
        let vp = document.querySelector('meta[name=viewport]');
        if (!vp) { vp = document.createElement('meta'); vp.name = 'viewport'; document.head.appendChild(vp); }
        vp.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';

        injectCSS();

        const bar    = mk('div', 'mb-bar');
        const keyRow = mk('div', 'mb-keys');
        const inpRow = mk('div', 'mb-input-row');
        const arrows = mk('div', 'mb-arrows');
        const tmux   = mk('div', 'mb-tmux');
        bar.append(keyRow, inpRow);
        document.body.append(bar, arrows, tmux);

        // ── Modifier state ────────────────────────────────────────────────────
        let ctrlOn = false, shiftOn = false, tmuxMode = false;

        function clearCtrl()  { ctrlOn  = false; kEl.ctrl.classList.remove('mod-on'); }
        function clearShift() { shiftOn = false; kEl.shft.classList.remove('mod-on'); }
        function clearTmux()  { tmuxMode = false; kEl.cb.classList.remove('mod-on'); tmux.classList.remove('show'); }
        function vib(ms)      { if (navigator.vibrate) navigator.vibrate(ms); }

        // ── Key row definitions ───────────────────────────────────────────────
        // ↵ sends the textarea content (same as Send button) — not just a newline.
        // CTRL enters combo mode: next Send transmits ctrl+char.
        // SHF toggles shift for Tab and arrow keys.
        // ↕ toggles the arrow popup.
        const KEYS = [
            { id: 'esc',  label: 'Esc',  seq: '\x1b' },
            { id: 'cc',   label: 'C-c',  seq: '\x03',  cls: 'danger' },
            {
                id: 'cb', label: 'C-b', cls: 'accent',
                fn: () => {
                    if (tmuxMode) { clearTmux(); vib(10); return; }
                    sendData('\x02');
                    tmuxMode = true;
                    kEl.cb.classList.add('mod-on');
                    positionTmux();
                    tmux.classList.add('show');
                    vib(15); inp.focus();
                }
            },
            {
                id: 'tab', label: 'Tab',
                fn: () => { sendData(shiftOn ? '\x1b[Z' : '\t'); clearShift(); vib(10); }
            },
            {
                id: 'ctrl', label: 'CTRL', cls: 'mod',
                fn: () => {
                    ctrlOn = !ctrlOn;
                    if (ctrlOn) clearShift();
                    kEl.ctrl.classList.toggle('mod-on', ctrlOn);
                    vib(15); inp.focus();
                }
            },
            {
                id: 'shft', label: 'SHF', cls: 'mod',
                fn: () => {
                    shiftOn = !shiftOn;
                    if (shiftOn) clearCtrl();
                    kEl.shft.classList.toggle('mod-on', shiftOn);
                    vib(15);
                }
            },
            { id: 'arr', label: '↕', cls: 'mod', fn: toggleArrows },
        ];

        const kEl = {};
        KEYS.forEach(k => {
            const b = mk('div', `mb-key${k.cls ? ' ' + k.cls : ''}`);
            b.textContent = k.label;
            b._key = k;
            kEl[k.id] = b;
            keyRow.appendChild(b);
        });

        // ── Textarea ──────────────────────────────────────────────────────────
        const inp = document.createElement('textarea');
        inp.id = 'mb-inp';
        inp.rows = 1;
        inp.placeholder = '';
        inp.setAttribute('autocomplete',  'off');
        inp.setAttribute('autocorrect',   'off');
        inp.setAttribute('autocapitalize','none');
        inp.setAttribute('spellcheck',    'false');
        inp.setAttribute('inputmode',     'text')
        inp.setAttribute('enterkeyhint',  'send');
        inp.addEventListener('keydown', e => e.stopPropagation());
        inp.addEventListener('input', () => {
            inp.style.height = 'auto';
            inp.style.height = Math.min(inp.scrollHeight, 100) + 'px';
        });

        const sendBtn = mk('button', 'mb-send');
        sendBtn.textContent = '↵';
        inpRow.append(inp, sendBtn);

        // ── Arrow popup ───────────────────────────────────────────────────────
        buildArrows(arrows);

        // ── Send logic ────────────────────────────────────────────────────────
        const doSend = () => {
            // Reload to reconnect only when truly disconnected.
            // window.socket may be null if ttyd stores it elsewhere; sendData
            // falls back to window.term.input which works regardless.
            const connected = window.socket?.readyState === 1;
            const canSend = connected || !!window.term?.input;
            if (!canSend) {
                location.reload();
                return;
            }
            const text = inp.value;
            if (ctrlOn) {
                const c = text.trim().charAt(0).toUpperCase();
                if (c >= 'A' && c <= 'Z') sendData(String.fromCharCode(c.charCodeAt(0) - 64));
                clearCtrl(); inp.value = ''; inp.style.height = 'auto'; vib(10);
                return;
            }
            if (tmuxMode) {
                // Send tmux command key(s) without trailing \r
                if (text) sendData(text);
                clearTmux(); inp.value = ''; inp.style.height = 'auto'; vib(10);
                return;
            }
            if (text) {
                sendData(text);
                setTimeout(() => sendData('\r'), SEND_DELAY_MS);
            } else {
                sendData('\r');
            }
            inp.value = ''; inp.style.height = 'auto'; vib(20);
        };
        sendBtn.addEventListener('touchend', e => { e.preventDefault(); doSend(); });
        sendBtn.addEventListener('click', doSend);

        // ── Touch: single-finger scrolls terminal (both 1 and 2 finger) ─────────
        let touchY = null;
        const getTouchY = (e) => e.touches.length === 2
            ? (e.touches[0].clientY + e.touches[1].clientY) / 2
            : e.touches[0].clientY;

        container.addEventListener('touchstart', e => {
            if (e.target.closest('.mb-bar, .mb-arrows')) return;
            e.preventDefault();
            e.stopPropagation();
            touchY = getTouchY(e);
        }, { passive: false, capture: true });

        container.addEventListener('touchmove', e => {
            e.preventDefault();
            e.stopPropagation();
            if (touchY === null) return;
            const y = getTouchY(e);
            const delta = touchY - y;
            const lines = Math.round(delta / 20);
            if (lines) {
                const isAltScreen = window.term?.buffer?.active?.type === 'alternate';
                if (isAltScreen) {
                    const seq = delta > 0 ? '\x1b[6~' : '\x1b[5~';
                    for (let i = 0; i < Math.abs(lines); i++) sendData(seq);
                } else if (window.term?.scrollLines) {
                    window.term.scrollLines(lines);
                }
                touchY = y;
            }
        }, { passive: false, capture: true });

        container.addEventListener('touchend', () => { touchY = null; }, { capture: true });

        // ── Key row touch ─────────────────────────────────────────────────────
        let activeKey = null;
        keyRow.addEventListener('touchstart', e => {
            const b = e.target.closest('.mb-key');
            if (!b) return; e.preventDefault();
            activeKey = b; b.classList.add('tap');
        }, { passive: false });
        keyRow.addEventListener('touchend', e => {
            e.preventDefault();
            if (!activeKey) return;
            activeKey.classList.remove('tap');
            const k = activeKey._key;
            if (k.fn) k.fn(); else if (k.seq) { sendData(k.seq); vib(10); }
            activeKey = null;
        }, { passive: false });
        keyRow.addEventListener('touchcancel', () => {
            if (activeKey) { activeKey.classList.remove('tap'); activeKey = null; }
        });

        // ── Arrow panel touch ─────────────────────────────────────────────────
        let activeArrow = null;
        arrows.addEventListener('touchstart', e => {
            const b = e.target.closest('.mb-key:not(.empty)');
            if (!b) return; e.preventDefault();
            activeArrow = b; b.classList.add('tap');
        }, { passive: false });
        arrows.addEventListener('touchend', e => {
            e.preventDefault();
            if (!activeArrow) return;
            activeArrow.classList.remove('tap');
            if (activeArrow.dataset.action === 'close') {
                arrows.classList.remove('show');
            } else {
                const seq = activeArrow._getSeq ? activeArrow._getSeq() : activeArrow.dataset.seq;
                if (seq) {
                    sendData(seq);
                    if (activeArrow._getSeq && shiftOn) clearShift();
                    vib(10);
                }
            }
            activeArrow = null;
        }, { passive: false });
        arrows.addEventListener('touchcancel', () => {
            if (activeArrow) { activeArrow.classList.remove('tap'); activeArrow = null; }
        });

        // ── Tmux panel touch ──────────────────────────────────────────────────
        let activeTmux = null;
        tmux.addEventListener('touchstart', e => {
            const b = e.target.closest('.mb-key:not(.empty)');
            if (!b) return; e.preventDefault();
            activeTmux = b; b.classList.add('tap');
        }, { passive: false });
        tmux.addEventListener('touchend', e => {
            e.preventDefault();
            if (!activeTmux) return;
            activeTmux.classList.remove('tap');
            if (activeTmux.dataset.action === 'close') {
                clearTmux();
            } else {
                const seq = activeTmux.dataset.seq;
                if (seq) { sendData(seq); vib(10); }
                clearTmux();
            }
            activeTmux = null;
        }, { passive: false });
        tmux.addEventListener('touchcancel', () => {
            if (activeTmux) { activeTmux.classList.remove('tap'); activeTmux = null; }
        });

        buildTmux(tmux);

        // ── Visual viewport: stay above keyboard, shrink terminal to match ───────
        const updateLayout = () => {
            const vv = window.visualViewport;
            const kbH = vv ? Math.max(0, window.innerHeight - vv.offsetTop - vv.height) : 0;
            bar.style.bottom = kbH + 'px';
            const barH = bar.offsetHeight;
            document.documentElement.style.setProperty('--mb-bar-h', (barH + kbH) + 'px');

            // Explicitly set terminal height so xterm.js reflows when keyboard appears/disappears.
            // Use setProperty('important') to override ttyd's own !important height rules.
            const tc = document.querySelector('#terminal-container');
            if (tc && vv) tc.style.setProperty('height', (vv.height - barH) + 'px', 'important');

            // Double-RAF: let layout settle before xterm.js measures container dimensions
            requestAnimationFrame(() => requestAnimationFrame(() => window.dispatchEvent(new Event('resize'))));
            if (arrows.classList.contains('show')) positionArrows();
            if (tmux.classList.contains('show'))   positionTmux();
        };
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', updateLayout);
            window.visualViewport.addEventListener('scroll', updateLayout);
        }
        new ResizeObserver(updateLayout).observe(bar);
        requestAnimationFrame(updateLayout);

        // ── Keep input focused ─────────────────────────────────────────────────
        inp.addEventListener('blur', () => {
            setTimeout(() => {
                if (document.activeElement !== inp && document.activeElement !== sendBtn) inp.focus();
            }, 80);
        });
        setTimeout(() => inp.focus(), 600);

        // ── Arrow popup helpers ───────────────────────────────────────────────
        function toggleArrows() {
            const show = !arrows.classList.contains('show');
            if (show) positionArrows();
            arrows.classList.toggle('show', show);
            vib(15);
        }

        function positionArrows() {
            const r  = kEl.arr.getBoundingClientRect();
            const br = bar.getBoundingClientRect();
            arrows.style.left   = Math.min(r.left, window.innerWidth - 160) + 'px';
            arrows.style.bottom = (window.innerHeight - br.top + 6) + 'px';
        }

        // ── Tmux popup helpers ────────────────────────────────────────────────
        function positionTmux() {
            const r  = kEl.cb.getBoundingClientRect();
            const br = bar.getBoundingClientRect();
            const w  = 4 * 46 + 3 * 4 + 12; // 4 cols × 46px + gaps + padding ≈ 208px
            tmux.style.left   = Math.min(r.left, window.innerWidth - w) + 'px';
            tmux.style.bottom = (window.innerHeight - br.top + 6) + 'px';
        }

        // ── Build tmux panel ──────────────────────────────────────────────────
        function buildTmux(panel) {
            // Common tmux bindings: label, char sent after prefix
            const CMDS = [
                { t: 'c',  s: 'c',  tip: 'new win'   },
                { t: 'n',  s: 'n',  tip: 'next win'  },
                { t: 'p',  s: 'p',  tip: 'prev win'  },
                { t: '%',  s: '%',  tip: 'vsplit'     },
                { t: '"',  s: '"',  tip: 'hsplit'     },
                { t: 'z',  s: 'z',  tip: 'zoom'       },
                { t: 'o',  s: 'o',  tip: 'next pane' },
                { t: '[',  s: '[',  tip: 'copy mode'  },
                { t: 'd',  s: 'd',  tip: 'detach'     },
                { t: 'x',  s: 'x',  tip: 'kill pane' },
                { t: ',',  s: ',',  tip: 'rename'     },
                { t: '✕',  action: 'close'            },
            ];
            const grid = mk('div', 'tmux-grid');
            CMDS.forEach(k => {
                const b = mk('div', 'mb-key');
                b.textContent = k.t;
                if (k.action) b.dataset.action = k.action;
                else          b.dataset.seq    = k.s;
                if (k.tip) b.title = k.tip;
                grid.appendChild(b);
            });
            panel.appendChild(grid);
        }

        // ── Build arrow panel ─────────────────────────────────────────────────
        function buildArrows(panel) {
            const DEFS = [
                null,
                { t: '▲', s: '\x1b[A',    ss: '\x1b[1;2A' },
                null,
                { t: '◀', s: '\x1b[D',    ss: '\x1b[1;2D' },
                { t: '▼', s: '\x1b[B',    ss: '\x1b[1;2B' },
                { t: '▶', s: '\x1b[C',    ss: '\x1b[1;2C' },
                { t: '⇞', s: '\x1b[5~' },
                { t: '⇟', s: '\x1b[6~' },
                { t: '✕', action: 'close' },
            ];
            const grid = mk('div', 'arrow-grid');
            DEFS.forEach(k => {
                const b = mk('div', k ? 'mb-key' : 'mb-key empty');
                if (k) {
                    b.textContent = k.t;
                    if (k.action)      b.dataset.action = k.action;
                    else if (k.ss)     b._getSeq = () => shiftOn ? k.ss : k.s;
                    else if (k.s)      b.dataset.seq = k.s;
                }
                grid.appendChild(b);
            });
            panel.appendChild(grid);
        }
    }

    // ── Shared helpers ─────────────────────────────────────────────────────────
    function mk(tag, cls) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        return e;
    }

    function injectCSS() {
        const s = document.createElement('style');
        s.textContent = `
            .mb-bar {
                position: fixed; left: 0; right: 0; bottom: 0;
                z-index: 2147483647;
                background: rgba(13,13,18,0.97);
                border-top: 1px solid rgba(255,255,255,0.1);
                backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
                padding: 4px;
                padding-bottom: calc(4px + env(safe-area-inset-bottom, 0px));
                display: flex; flex-direction: column; gap: 3px;
                touch-action: none; user-select: none; -webkit-user-select: none;
            }
            .mb-keys { display: flex; gap: 3px; }
            .mb-input-row { display: flex; gap: 3px; align-items: flex-end; }
            .mb-key {
                flex: 1; height: 34px; min-width: 0;
                background: rgba(255,255,255,0.08); color: #ccc;
                border-radius: 6px; border: 1px solid rgba(255,255,255,0.06);
                font: 700 11px/1 monospace;
                display: flex; align-items: center; justify-content: center;
                white-space: nowrap; overflow: hidden;
            }
            .mb-key.danger { background: rgba(200,50,50,0.28);  color: #f99; border-color: rgba(200,50,50,0.3); }
            .mb-key.accent { background: rgba(30,100,220,0.28); color: #aad; border-color: rgba(30,100,220,0.3); }
            .mb-key.mod    { background: rgba(55,55,75,0.6);    color: #99b; }
            .mb-key.mod-on { background: rgba(255,165,0,0.38)  !important; color: #ffd !important; border-color: rgba(255,165,0,0.55) !important; }
            .mb-key.tap    { background: rgba(255,255,255,0.25) !important; transform: scale(0.91); }
            .mb-key.empty  { background: transparent !important; border-color: transparent !important; pointer-events: none; }
            #mb-inp {
                flex: 1; min-height: 34px; max-height: 100px;
                background: rgba(22,22,32,0.98); color: #e0e0e0;
                border: 1px solid rgba(255,255,255,0.14); border-radius: 6px;
                font: 16px/1.4 monospace; padding: 7px 9px;
                resize: none; outline: none; touch-action: auto;
            }
            #mb-inp:focus { border-color: #2a8; }
            .mb-send {
                width: 42px; min-height: 34px; flex-shrink: 0;
                background: #0a7; color: #fff; border: none; border-radius: 6px;
                font-size: 15px; cursor: pointer;
                display: flex; align-items: center; justify-content: center;
            }
            .mb-send:active { background: #0c8; }
            .mb-arrows, .mb-tmux {
                display: none; position: fixed; z-index: 2147483646;
                background: rgba(13,13,18,0.97);
                border: 1px solid rgba(255,255,255,0.12); border-radius: 10px;
                padding: 6px;
                backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
                touch-action: none; user-select: none; -webkit-user-select: none;
            }
            .mb-arrows.show, .mb-tmux.show { display: block; }
            .arrow-grid {
                display: grid;
                grid-template-columns: repeat(3, 42px);
                grid-template-rows: repeat(3, 42px);
                gap: 4px;
            }
            .arrow-grid .mb-key { flex: none; width: 42px; height: 42px; font-size: 17px; }
            .tmux-grid {
                display: grid;
                grid-template-columns: repeat(4, 46px);
                gap: 4px;
            }
            .tmux-grid .mb-key { flex: none; width: 46px; height: 40px; font-size: 15px; }
            #terminal-container { bottom: var(--mb-bar-h, 0px) !important; }
        `;
        document.head.appendChild(s);
    }
})();
