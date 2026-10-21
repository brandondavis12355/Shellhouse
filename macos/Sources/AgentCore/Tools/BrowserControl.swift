import Foundation

/// Driving the page itself instead of aiming at pixels. A vision model reads positions off a screenshot badly (a bot clicked "Receive" six
/// times believing it was "Reports", and an X mouse click on a page can also simply be ignored), but the page knows where every link and
/// field is. The browser is started with a remote-control port on the VM's own loopback (`open_app`), and these operations talk to it:
/// find an element by its visible text, click it with real mouse events at its centre, fill a field, read the page's text.
/// A small Python script (standard library only; Python is in the VM) does the work and prints one line of JSON; it ships with the app.
public enum BrowserControl {
    public static let port = 9222
    /// Where the browser keeps its profile: remote control needs a profile of its own (newer Chromium refuses it on the default one).
    public static let profileDir = "$HOME/.config/shellhouse-chromium"
    public static let launchFlags = "--remote-debugging-port=\(port) --user-data-dir=\(profileDir) --no-first-run --no-default-browser-check --disable-notifications --disable-infobars"

    /// Turns off the browser's own "save password?" and autofill prompts in the profile: they are Chromium's interface, not the page's, so
    /// `click_text` can't reach them and a bot spent a run trying to click one. Run before a fresh start (Chromium rewrites its settings on exit).
    public static let quietProfile: String = {
        let code = """
        import json, os
        d = os.path.expandvars("\(profileDir)/Default"); os.makedirs(d, exist_ok=True)
        p = d + "/Preferences"
        try: j = json.load(open(p))
        except Exception: j = {}
        j["credentials_enable_service"] = False
        j.setdefault("profile", {})["password_manager_enabled"] = False
        j.setdefault("autofill", {})["profile_enabled"] = False
        j["autofill"]["credit_card_enabled"] = False
        json.dump(j, open(p, "w"))
        """
        return "python3 -c " + shellQuote(code)
    }()

    public enum Operation: String { case find, click, fill, text, aim }

    /// The shell command that runs one operation. `args` are passed as arguments, quoted.
    public static func command(_ operation: Operation, _ args: [String], port: Int = BrowserControl.port) -> String {
        let quoted = args.map(shellQuote).joined(separator: " ")
        return GUICommand.wrap("SHELLHOUSE_CDP_PORT=\(port) python3 - \(operation.rawValue) \(quoted) <<'PY'\n\(script)\nPY")
    }

    public static let script = #"""
    import base64, http.client, json, os, socket, struct, subprocess, sys, time, urllib.parse
    PORT = int(os.environ.get("SHELLHOUSE_CDP_PORT", "9222"))

    def out(obj):
        print(json.dumps(obj)); sys.exit(0)

    def fail(code, detail):
        out({"error": code, "detail": detail})

    try:
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=4)
        c.request("GET", "/json"); targets = json.loads(c.getresponse().read()); c.close()
    except Exception as e:
        fail("browser_not_controllable", str(e))
    pages = [t for t in targets if t.get("type") == "page" and not t.get("url", "").startswith("devtools://")]
    if not pages:
        fail("no_page", "the browser has no open page")

    class WS:
        def __init__(self, url):
            u = urllib.parse.urlparse(url)
            self.s = socket.create_connection((u.hostname, u.port), timeout=10)
            key = base64.b64encode(os.urandom(16)).decode()
            self.s.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (u.path, u.hostname, u.port, key)).encode())
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = self.s.recv(4096)
                if not chunk: raise RuntimeError("websocket handshake failed")
                buf += chunk
            head, _, self.buf = buf.partition(b"\r\n\r\n")
            if b" 101 " not in head.split(b"\r\n")[0]: raise RuntimeError("websocket refused: " + head.split(b"\r\n")[0].decode())
            self.n = 0
        def _read(self, n):
            while len(self.buf) < n:
                chunk = self.s.recv(65536)
                if not chunk: raise EOFError("connection closed")
                self.buf += chunk
            data, self.buf = self.buf[:n], self.buf[n:]
            return data
        def send(self, obj):
            data = json.dumps(obj).encode(); n = len(data); head = bytearray([0x81])
            if n < 126: head.append(0x80 | n)
            elif n < 65536: head.append(0x80 | 126); head += struct.pack(">H", n)
            else: head.append(0x80 | 127); head += struct.pack(">Q", n)
            mask = os.urandom(4); head += mask
            self.s.sendall(bytes(head) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
        def recv(self):
            msg = b""
            while True:
                b1, b2 = self._read(2); fin, op, ln = b1 & 0x80, b1 & 0x0F, b2 & 0x7F
                if ln == 126: ln = struct.unpack(">H", self._read(2))[0]
                elif ln == 127: ln = struct.unpack(">Q", self._read(8))[0]
                payload = self._read(ln)
                if op == 8: raise EOFError("closed")
                if op in (0, 1, 2):
                    msg += payload
                    if fin: return msg.decode()
        def call(self, method, params=None):
            self.n += 1; mine = self.n
            self.send({"id": mine, "method": method, "params": params or {}})
            while True:
                m = json.loads(self.recv())
                if m.get("id") == mine:
                    if "error" in m: raise RuntimeError(m["error"].get("message", "browser error"))
                    return m.get("result", {})

    ws = WS(pages[0]["webSocketDebuggerUrl"])

    def js(expr):
        r = ws.call("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True})
        if "exceptionDetails" in r: raise RuntimeError(r["exceptionDetails"].get("text", "script error"))
        return r.get("result", {}).get("value")

    FIND = r"""
    ((q, mode) => {
      const norm = s => (s || '').replace(/\s+/g, ' ').trim();
      const sel = mode === 'field'
        ? 'input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=image]),textarea,select,[contenteditable=true],[contenteditable=""]'
        : 'a,button,input,select,textarea,summary,label,[role=button],[role=link],[role=tab],[role=menuitem],[role=option],[onclick],[tabindex]';
      const labelOf = e => {
        const own = norm(e.innerText) || norm(e.value);
        if (mode !== 'field') return own || norm(e.getAttribute('aria-label')) || norm(e.placeholder) || norm(e.title) || norm(e.alt) || norm(e.name);
        const parts = [e.getAttribute('aria-label'), e.placeholder, e.name, e.id, e.title];
        (e.labels ? Array.from(e.labels) : []).forEach(l => parts.push(l.innerText));
        const prev = e.previousElementSibling; if (prev) parts.push(prev.innerText);
        const par = e.parentElement; if (par && par.querySelectorAll(sel).length === 1) parts.push(par.innerText);
        return parts.map(norm).filter(Boolean).join(' | ');
      };
      const out = [];
      document.querySelectorAll(sel).forEach(e => {
        const r = e.getBoundingClientRect(); if (r.width < 2 || r.height < 2) return;
        const st = getComputedStyle(e); if (st.visibility === 'hidden' || st.display === 'none') return;
        const l = labelOf(e); if (!l) return;
        out.push({e, l, tag: e.tagName.toLowerCase(), type: e.type || '', r});
      });
      const t = q.toLowerCase();
      const score = o => { const l = o.l.toLowerCase(); return l === t ? 0 : l.split(' | ').includes(t) ? 0 : l.startsWith(t) ? 1 : l.includes(t) ? 2 : 9; };
      const pri = o => (o.tag === 'button' || (o.tag === 'input' && /^(submit|button)$/.test(o.type))) ? 0 : 1;
      const hits = out.filter(o => score(o) < 9).sort((a, b) => score(a) - score(b) || pri(a) - pri(b) || a.r.top - b.r.top || a.r.left - b.r.left);
      window.__shMatches = hits.map(h => h.e);
      return JSON.stringify({
        win: {sx: window.screenX, sy: window.screenY + (window.outerHeight - window.innerHeight), w: innerWidth, h: innerHeight},
        others: out.slice(0, 15).map(o => o.l.slice(0, 60)),
        matches: hits.slice(0, 12).map((h, i) => ({i, label: h.l.slice(0, 80), tag: h.tag, type: h.type,
          x: Math.round(h.r.left + h.r.width / 2), y: Math.round(h.r.top + h.r.height / 2), w: Math.round(h.r.width), h: Math.round(h.r.height),
          inView: h.r.bottom > 0 && h.r.top < innerHeight && h.r.right > 0 && h.r.left < innerWidth}))
      });
    })
    """

    def find(query, mode="click"):
        return json.loads(js("%s(%s, %s)" % (FIND, json.dumps(query), json.dumps(mode))))

    def state():
        deadline = time.time() + 3
        while True:
            s = js("JSON.stringify({url: location.href, title: document.title, ready: document.readyState})")
            s = json.loads(s)
            if s["ready"] == "complete" or time.time() > deadline: return s
            time.sleep(0.2)

    def move_pointer(win, x, y):
        sx, sy = int(win["sx"] + x), int(win["sy"] + y)
        try: subprocess.run(["xdotool", "mousemove", str(sx), str(sy)], capture_output=True, timeout=3)
        except Exception: pass
        return {"x": sx, "y": sy}

    op = sys.argv[1]
    try:
        if op == "text":
            limit = int(sys.argv[2]) if len(sys.argv) > 2 else 6000
            body = js("document.body ? document.body.innerText : ''") or ""
            s = state()
            out({"url": s["url"], "title": s["title"], "text": body[:limit], "truncated": len(body) > limit, "length": len(body)})

        elif op == "find":
            r = find(sys.argv[2])
            s = state()
            out({"url": s["url"], "title": s["title"], "matches": r["matches"]})

        elif op == "click":
            query, index = sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 0
            before = state()
            r = find(query)
            if not r["matches"]:
                out({"error": "no_match", "detail": "nothing on the page is labelled like %r" % query, "url": before["url"], "title": before["title"]})
            if index >= len(r["matches"]): index = 0
            js("(() => { const e = window.__shMatches[%d]; e.scrollIntoView({block: 'center', inline: 'center'}); })()" % index)
            time.sleep(0.15)
            r = find(query)
            m = r["matches"][index] if index < len(r["matches"]) else r["matches"][0]
            x, y = m["x"], m["y"]
            pointer = move_pointer(r["win"], x, y)
            for t, extra in (("mouseMoved", {}), ("mousePressed", {"button": "left", "clickCount": 1}), ("mouseReleased", {"button": "left", "clickCount": 1})):
                ws.call("Input.dispatchMouseEvent", dict({"type": t, "x": x, "y": y}, **extra))
                time.sleep(0.04)
            time.sleep(0.6)
            after = state()
            out({"clicked": {"label": m["label"], "tag": m["tag"]}, "matches": len(r["matches"]), "pointer": pointer,
                 "url": after["url"], "title": after["title"], "navigated": after["url"] != before["url"]})

        elif op == "aim":
            # Scroll the target into view and report where the pointer will go, without clicking: the app shows the pointer
            # arriving first, then the real click or fill runs.
            query, index, mode = sys.argv[2], int(sys.argv[3]), sys.argv[4]
            r = find(query, mode)
            if not r["matches"]: out({"error": "no_match"})
            if index >= len(r["matches"]): index = 0
            js("(() => { const e = window.__shMatches[%d]; e.scrollIntoView({block: 'center', inline: 'center'}); })()" % index)
            time.sleep(0.15)
            r = find(query, mode)
            m = r["matches"][index] if index < len(r["matches"]) else r["matches"][0]
            out({"pointer": move_pointer(r["win"], m["x"], m["y"])})

        elif op == "fill":
            label, value = sys.argv[2], sys.argv[3]
            submit = len(sys.argv) > 4 and sys.argv[4] == "submit"
            r = find(label, "field")
            if not r["matches"]:
                s = state()
                out({"error": "no_match", "detail": "no field is labelled like %r" % label, "url": s["url"], "title": s["title"],
                     "fields_on_page": r.get("others", []),
                     "hint": "The browser IS under control, so do not restart it (that signs you out). Check url/title: if you are on the wrong page, go to the right one; otherwise pick a label from fields_on_page."})
            js("(() => { const e = window.__shMatches[0]; e.scrollIntoView({block: 'center'}); e.focus(); if (e.select) e.select(); })()")
            ws.call("Input.insertText", {"text": value})
            if submit:
                for t in ("keyDown", "keyUp"):
                    ws.call("Input.dispatchKeyEvent", {"type": t, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": "\r" if t == "keyDown" else ""})
                time.sleep(0.6)
            f = json.loads(js("JSON.stringify({v: (document.activeElement && document.activeElement.value) || ''})"))
            m = r["matches"][0]
            pointer = move_pointer(r["win"], m["x"], m["y"])
            after = state()
            out({"filled": {"label": m["label"], "tag": m["tag"]}, "value_length": len(f["v"]), "matches": len(r["matches"]), "submitted": submit,
                 "pointer": pointer, "url": after["url"], "title": after["title"]})
        else:
            fail("bad_operation", op)
    except SystemExit:
        raise
    except Exception as e:
        fail("browser_error", str(e))
    """#
}
