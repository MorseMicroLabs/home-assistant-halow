#!/usr/bin/env python3
"""HaLow access point status service.

A small, GET-only HTTP service that renders the add-on's Ingress page and serves
/status.json, /diagnostics (redacted) and /health from the snapshot the manager writes.
It runs as an unprivileged user, reads the snapshot read-only on every request, never
changes any state and has no control endpoints.

Python 3 standard library only.
"""

import argparse
import html
import http.server
import ipaddress
import json
import os
import re
import secrets
import signal
import socket
import sys
import threading
import time
import urllib.parse

SCHEMA = 2
MAX_SNAPSHOT_BYTES = 1024 * 1024
REQUEST_LINE_MAX = 4096
HEADER_COUNT_MAX = 50
HEADER_BYTES_MAX = 16384
SOCKET_TIMEOUT_S = 5
MAX_CONCURRENT = 16
DEFAULT_STALE_AFTER_S = "90"
READ_RETRY_DELAY_S = 0.05
PAGE_REFRESH_S = 5
NOSCRIPT_REFRESH_S = 15
# Liveness counter (see StatusServer.service_actions): rewritten at most this often.
HEARTBEAT_INTERVAL_S = 5
HEARTBEAT_COUNTER_MAX = 10 ** 18

ASSET_DIR = os.path.dirname(os.path.abspath(__file__))

# Same wording as the STATUS_STALE entry of the add-on's error catalogue (a test keeps
# the two identical).
STATUS_STALE_CODE = "STATUS_STALE"
STATUS_STALE_SUMMARY = (
    "The status has not been updated recently, so what you see may be out of date."
)
STATUS_STALE_ACTION = "Restart the app. If the message stays, check the app's Log tab."

# ---------------------------------------------------------------------------------------
# Redaction (applied again on output, whatever the snapshot contains)
# ---------------------------------------------------------------------------------------

REDACTED = "[redacted]"
_KEYS = r"(?:passphrase|password|passwd|psk|secret|token)"
_KEY_RE = re.compile(_KEYS, re.IGNORECASE)
_JSON_PAIR_RE = re.compile(
    r'("[^"\n]*' + _KEYS + r'[^"\n]*"[ \t]*:[ \t]*")((?:[^"\\\n]|\\.)*)(")',
    re.IGNORECASE,
)
_ASSIGN_RE = re.compile(r"(" + _KEYS + r")('?[ \t]*[=:]).*", re.IGNORECASE)
_HEX_RE = re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64,}(?![0-9A-Fa-f])")


def redact_text(text):
    """Remove secrets from one string (any number of lines)."""
    if not isinstance(text, str):
        return text
    out = []
    for line in text.split("\n"):
        line = _JSON_PAIR_RE.sub(lambda m: m.group(1) + REDACTED + m.group(3), line)
        line = _ASSIGN_RE.sub(lambda m: m.group(1) + m.group(2) + REDACTED, line, count=1)
        line = _HEX_RE.sub(REDACTED, line)
        out.append(line)
    return "\n".join(out)


def redact_obj(obj):
    """Redact every string in a JSON value; any value stored under a secret-like key
    (a string, a number, a list or an object) is replaced entirely. Only null and booleans
    under such a key are kept: they cannot carry a secret."""
    if isinstance(obj, dict):
        result = {}
        for key, value in obj.items():
            safe_key = redact_text(str(key))
            if _KEY_RE.search(str(key)) and not isinstance(value, bool) and value is not None:
                result[safe_key] = REDACTED
            else:
                result[safe_key] = redact_obj(value)
        return result
    if isinstance(obj, list):
        return [redact_obj(item) for item in obj]
    if isinstance(obj, str):
        return redact_text(obj)
    return obj


# ---------------------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------------------


def empty_snapshot():
    return {
        "schema": SCHEMA,
        "updated_at": None,
        "started_at": None,
        "boot_id": "",
        "overall": "starting",
        "attention": None,
        "advisory": None,
        "region": "",
        "radio": {
            "mode": "",
            "requested": {"bandwidth_mhz": None, "channel": None},
            "effective": None,
            "last_applied": None,
        },
        "adapter": {"present": False, "interface": ""},
        "backend": {"applied": False, "bridge": "", "subnet": "", "gateway": ""},
        "stations": [],
        "diagnostics": {},
    }


def _read_once(path):
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_SNAPSHOT_BYTES + 1)
    except FileNotFoundError:
        return None, "missing"
    except OSError:
        return None, "unreadable"
    if len(data) > MAX_SNAPSHOT_BYTES:
        return None, "unreadable"
    try:
        obj = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None, "unreadable"
    if not isinstance(obj, dict) or obj.get("schema") != SCHEMA:
        return None, "unreadable"
    return obj, None


def read_snapshot(path):
    """Return (snapshot or None, problem or None). Retries once on an unreadable file."""
    obj, problem = _read_once(path)
    if problem == "unreadable":
        time.sleep(READ_RETRY_DELAY_S)
        obj, problem = _read_once(path)
    return obj, problem


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


class View:
    """One request's view of the snapshot."""

    def __init__(self, snapshot, stale, stale_reason):
        self.snapshot = snapshot
        self.stale = stale
        self.stale_reason = stale_reason


def build_view(config, now=None):
    if now is None:
        now = time.time()
    obj, problem = read_snapshot(config.snapshot)
    if obj is None:
        snapshot = empty_snapshot()
        if problem == "missing" and now - config.started_at <= config.stale_after:
            stale, reason = False, None
        else:
            stale, reason = True, problem
    else:
        snapshot = obj
        updated = obj.get("updated_at")
        if not _is_int(updated):
            stale, reason = True, "unreadable"
        elif now - updated > config.stale_after:
            stale, reason = True, "old"
        else:
            stale, reason = False, None
    return View(redact_obj(snapshot), stale, reason)


def public_json(view, with_diagnostics):
    data = dict(view.snapshot)
    if not with_diagnostics:
        data.pop("diagnostics", None)
    elif not isinstance(data.get("diagnostics"), dict):
        data["diagnostics"] = {}
    data["stale"] = view.stale
    data["stale_reason"] = view.stale_reason
    return json.dumps(redact_obj(data), ensure_ascii=True, sort_keys=False, indent=1) + "\n"


# ---------------------------------------------------------------------------------------
# Page rendering (every dynamic value is escaped)
# ---------------------------------------------------------------------------------------

OVERALL_LINES = {
    "starting": "The access point is starting. This page updates by itself.",
    "operating": "The access point is running and devices can connect.",
}
OVERALL_LABELS = {
    "starting": "Starting",
    "operating": "Operating",
    "attention": "Attention required",
}
SOURCE_LABELS = {
    "acs": "Automatic selection",
    "manual": "Your manual setting",
    "fallback": "Backup channel (automatic selection did not complete)",
}
MODE_LABELS = {"automatic": "Automatic", "manual": "Manual"}


def esc(value):
    return html.escape(str(value), quote=True)


def _get(obj, *keys):
    for key in keys:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(key)
    return obj


def fmt_time(epoch):
    if not _is_int(epoch) or epoch <= 0:
        return "unknown"
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(epoch))
    except (OverflowError, OSError, ValueError):
        return "unknown"


def fmt_mhz(khz):
    if not _is_int(khz) or khz <= 0:
        return "Not reported"
    text = "%.3f" % (khz / 1000.0)
    text = text.rstrip("0").rstrip(".")
    return text + " MHz"


def fmt_bw(mhz):
    if not _is_int(mhz) or mhz <= 0:
        return "Not reported"
    return "%d MHz" % mhz


def fmt_int(value, missing="Not reported"):
    return str(value) if _is_int(value) else missing


def text_or(value, missing):
    if isinstance(value, str) and value:
        return value
    return missing


def _dl(rows):
    parts = ["<dl>"]
    for label, value in rows:
        parts.append("<dt>%s</dt><dd>%s</dd>" % (esc(label), esc(value)))
    parts.append("</dl>")
    return "".join(parts)


def _stale_section(view, updated_at):
    return (
        '<section class="banner banner-stale" role="alert">'
        "<h2>Status may be out of date</h2>"
        "<p>%s</p><p><strong>What to do:</strong> %s</p>"
        "<p class=\"meta\">Last update: %s. Error code: %s.</p>"
        "</section>"
        % (
            esc(STATUS_STALE_SUMMARY),
            esc(STATUS_STALE_ACTION),
            esc(fmt_time(updated_at)),
            esc(STATUS_STALE_CODE),
        )
    )


def _attention_section(att):
    host_clean = att.get("host_clean") is True
    host_text = (
        "The app has undone its changes to the system."
        if host_clean
        else "The app could not confirm that its changes to the system were undone."
    )
    parts = [
        '<section class="card card-attention" role="alert">',
        "<h2>Attention required</h2>",
        '<p class="summary">%s</p>' % esc(text_or(att.get("summary"), "Unknown problem.")),
        "<p><strong>What to do:</strong> %s</p>" % esc(text_or(att.get("action"), "Restart the app.")),
    ]
    detail = att.get("detail")
    if isinstance(detail, str) and detail:
        parts.append('<p class="detail">Details: %s</p>' % esc(detail))
    parts.append(
        _dl(
            [
                ("Since", fmt_time(att.get("since"))),
                ("System state", host_text),
                ("Error code", text_or(att.get("code"), "unknown")),
            ]
        )
    )
    parts.append("</section>")
    return "".join(parts)


def _radio_values(values):
    source = values.get("source")
    return [
        ("Frequency", fmt_mhz(values.get("frequency_khz"))),
        ("Channel", fmt_int(values.get("channel"))),
        ("Bandwidth", fmt_bw(values.get("bandwidth_mhz"))),
        ("Channel chosen by", SOURCE_LABELS.get(source, "Not reported")),
        ("Active since", fmt_time(values.get("applied_at"))),
    ]


def _advisory_section(adv, effective):
    parts = [
        '<section class="banner banner-advisory" role="alert">',
        "<h2>Using a backup channel</h2>",
        "<p>%s</p>" % esc(text_or(adv.get("summary"), "An advisory is active.")),
        "<p>%s</p>" % esc(text_or(adv.get("action"), "")),
        '<p class="meta">Since %s.</p>' % esc(fmt_time(adv.get("since"))),
    ]
    parts.append("</section>")
    return "".join(parts)


def _radio_section(snap):
    radio = snap.get("radio") if isinstance(snap.get("radio"), dict) else {}
    mode = radio.get("mode")
    requested = radio.get("requested") if isinstance(radio.get("requested"), dict) else {}
    if mode == "automatic":
        req_channel = "Automatic (chosen each time the app starts)"
    else:
        req_channel = fmt_int(requested.get("channel"), "Not set")
    rows = [
        ("Region", text_or(snap.get("region"), "Not set")),
        ("Channel selection mode", MODE_LABELS.get(mode, "Not set")),
        ("Bandwidth setting", fmt_bw(requested.get("bandwidth_mhz")).replace("Not reported", "Not set")),
        ("Channel setting", req_channel),
    ]
    parts = [
        '<section class="card"><h2>Wi-Fi HaLow radio</h2><h3>Your settings</h3>',
        _dl(rows),
        '<p class="note">Changes to the app options take effect after you restart the app.</p>',
    ]
    effective = radio.get("effective")
    last = radio.get("last_applied")
    if isinstance(effective, dict):
        parts.append("<h3>In use now</h3>")
        parts.append(_dl(_radio_values(effective)))
        shown = effective
    elif snap.get("overall") == "operating":
        # The access point runs but its radio values could not be read back.
        parts.append(
            "<h3>In use now</h3><p>The access point is running, but its active radio values "
            "cannot be read right now. The values above are your settings.</p>"
        )
        shown = None
    elif isinstance(last, dict):
        parts.append(
            "<h3>Last values used (access point not running), as of %s</h3>"
            % esc(fmt_time(last.get("applied_at")))
        )
        parts.append(_dl(_radio_values(last)))
        shown = last
    else:
        parts.append("<h3>In use now</h3><p>Not available yet. The access point has not started.</p>")
        shown = None
    parts.append(
        '<p class="note">If a device cannot find the network by itself, set it to the '
        'frequency and bandwidth shown under "In use now".</p>'
    )
    parts.append("</section>")
    return "".join(parts)


def _system_section(snap):
    present = _get(snap, "adapter", "present") is True
    applied = _get(snap, "backend", "applied") is True
    rows = [
        ("Wi-Fi HaLow USB Network Adapter", "Detected" if present else "Not detected"),
        ("Networking", "Active" if applied else "Not active"),
    ]
    return '<section class="card"><h2>Adapter and network</h2>%s</section>' % _dl(rows)


KIND_LABELS = {
    "ordinary": "",
    "wds": "Connects other devices",
}
IP_CONFLICT_TEXT = "Another device may also use this address."


def _label(table, key, default):
    """A label for a value that came from the snapshot: only a string can be a key."""
    return table.get(key, default) if isinstance(key, str) else default


def _ip_items(ips):
    """The address entries of one MAC as list items (an empty string when there are none).
    Every value is escaped; an entry that is not an object is ignored."""
    items = []
    if not isinstance(ips, list):
        return ""
    for entry in ips:
        if not isinstance(entry, dict):
            continue
        ip = entry.get("ip")
        if not isinstance(ip, str) or not ip:
            continue
        text = "<span class=\"mono\">%s</span>%s" % (
            esc(ip),
            " <span class=\"meta\">%s</span>" % esc(IP_CONFLICT_TEXT) if entry.get("conflict") is True else "",
        )
        items.append(text)
    return "; ".join(items)


def _station_time(st, online):
    since = st.get("connected_since")
    changed = st.get("state_changed_at")
    if online and _is_int(since) and since > 0:
        return "Connected since %s" % fmt_time(since)
    return "Last change: %s" % fmt_time(changed)


def _station_devices(st):
    """The 'Devices and IP addresses' cell of one station row."""
    kind = st.get("kind")
    own = _ip_items(st.get("ips"))
    lines = []
    if kind == "wds":
        if own:
            lines.append("<li>This device: %s</li>" % own)
        devices = st.get("devices")
        shown = 0
        if isinstance(devices, list):
            for dev in devices:
                if not isinstance(dev, dict):
                    continue
                shown += 1
                addrs = _ip_items(dev.get("ips"))
                lines.append(
                    "<li><span class=\"mono\">%s</span>: %s</li>"
                    % (esc(text_or(dev.get("mac"), "unknown")), addrs if addrs else "IP address not available")
                )
        omitted = st.get("devices_omitted")
        if _is_int(omitted) and omitted > 0:
            lines.append("<li>%d more devices not shown.</li>" % omitted)
        if shown == 0 and not (_is_int(omitted) and omitted > 0):
            if st.get("online") is True:
                lines.append("<li>No other devices are connected through it right now.</li>")
            else:
                lines.append("<li>No other devices listed.</li>")
    else:
        lines.append("<li>%s</li>" % (own if own else "Not available"))
    return "<ul class=\"devs\">%s</ul>" % "".join(lines)


def _stations_section(snap):
    stations = snap.get("stations")
    if not isinstance(stations, list):
        stations = []
    parts = ['<section class="card"><h2>Connected devices</h2>']
    rows = [st for st in stations if isinstance(st, dict)]
    if not rows:
        parts.append("<p>No devices have connected since the app started.</p>")
    else:
        parts.append(
            '<div class="table-wrap"><table><thead><tr><th scope="col">Device (MAC address)</th>'
            '<th scope="col">Status</th><th scope="col">Time</th>'
            '<th scope="col">IP address</th></tr></thead><tbody>'
        )
        for st in rows:
            online = st.get("online") is True
            parts.append(
                '<tr><td data-label="Device"><span class="mono">%s</span>%s</td>'
                '<td data-label="Status"><span class="pill %s">%s</span>%s</td>'
                '<td data-label="Time">%s</td><td data-label="IP address">%s</td></tr>'
                % (
                    esc(text_or(st.get("mac"), "unknown")),
                    ('<br><span class="meta">%s</span>' % esc(_label(KIND_LABELS, st.get("kind"), ""))) if _label(KIND_LABELS, st.get("kind"), "") else "",
                    "pill-on" if online else "pill-off",
                    "Online" if online else "Offline",
                    "" if st.get("online_source") == "hostapd" else '<br><span class="meta">status estimated</span>',
                    esc(_station_time(st, online)),
                    _station_devices(st),
                )
            )
        parts.append("</tbody></table></div>")
    parts.append(
        '<p class="note">Devices that have joined the Wi-Fi HaLow network since the app started. '
        "Online and Offline show the connection to the access point, not whether a device is sending data.</p>"
    )
    parts.append("</section>")
    return "".join(parts)


def render_main(view):
    snap = view.snapshot
    overall = snap.get("overall")
    if view.stale:
        label, css = "Attention required", "attention"
    else:
        label = OVERALL_LABELS.get(overall, "Starting")
        css = overall if overall in OVERALL_LABELS else "starting"
    line = ""
    shown = overall if overall in OVERALL_LABELS else "starting"
    if not view.stale and shown in OVERALL_LINES:
        line = '<p class="note">%s</p>' % esc(OVERALL_LINES[shown])
    parts = [
        '<header class="top"><h1>Wi-Fi HaLow access point</h1>',
        '<p class="state state-%s"><span class="dot" aria-hidden="true"></span>%s</p>%s</header>'
        % (esc(css), esc(label), line),
    ]
    if view.stale:
        parts.append(_stale_section(view, snap.get("updated_at")))
    att = snap.get("attention")
    if isinstance(att, dict) and (overall == "attention" or view.stale):
        parts.append(_attention_section(att))
    elif overall == "attention" and not view.stale:
        parts.append(
            '<section class="card card-attention" role="alert"><h2>Attention required</h2>'
            "<p>No further details are available.</p></section>"
        )
    adv = snap.get("advisory")
    effective = _get(snap, "radio", "effective")
    if isinstance(adv, dict):
        parts.append(_advisory_section(adv, effective))
    parts.append(_radio_section(snap))
    parts.append(_system_section(snap))
    parts.append(_stations_section(snap))
    parts.append(
        '<footer>'
        '<p class="meta">Last update: %s. <a href="diagnostics">Diagnostics for support</a> '
        "(passphrase removed; includes device addresses)</p>"
        "</footer>" % esc(fmt_time(snap.get("updated_at")))
    )
    return "".join(parts)


class Assets:
    def __init__(self, directory):
        with open(os.path.join(directory, "page.html"), "r", encoding="utf-8") as handle:
            self.template = handle.read()
        with open(os.path.join(directory, "page.css"), "r", encoding="utf-8") as handle:
            self.css = handle.read()
        with open(os.path.join(directory, "page.js"), "r", encoding="utf-8") as handle:
            self.js = handle.read()


def render_page(assets, view, nonce):
    page = assets.template
    page = page.replace("@@NONCE@@", nonce)
    page = page.replace("@@NOSCRIPT_REFRESH@@", str(NOSCRIPT_REFRESH_S))
    page = page.replace("@@CSS@@", assets.css)
    page = page.replace("@@SCRIPT@@", assets.js.replace("@@REFRESH_MS@@", str(PAGE_REFRESH_S * 1000)))
    page = page.replace("@@MAIN@@", render_main(view))
    return page


# ---------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------


class Config:
    def __init__(self, snapshot, stale_after, allow, assets):
        self.snapshot = snapshot
        self.stale_after = stale_after
        self.allow = allow  # None means any peer (tests only)
        self.assets = assets
        self.started_at = time.time()


def parse_allow(value):
    value = (value or "").strip()
    if value == "any":
        return None
    allowed = set()
    for item in re.split(r"[,\s]+", value):
        if not item:
            continue
        allowed.add(ipaddress.ip_address(item))
    if not allowed:
        raise ValueError("no allowed peer address given")
    return allowed


def peer_allowed(allow, address):
    if allow is None:
        return True
    try:
        peer = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(peer, ipaddress.IPv6Address) and peer.ipv4_mapped is not None:
        peer = peer.ipv4_mapped
    return peer in allow


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "halow-status"
    sys_version = ""
    protocol_version = "HTTP/1.0"
    timeout = SOCKET_TIMEOUT_S

    # Never log requests, headers, bodies or the snapshot.
    def log_message(self, format, *args):  # noqa: A002 (signature from the base class)
        return

    def _send(self, status, body, content_type, extra=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Connection", "close")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def _plain(self, status, text, extra=None):
        self._send(status, text + "\n", "text/plain; charset=utf-8", extra)

    def handle_one_request(self):
        self.close_connection = True
        try:
            self.raw_requestline = self.rfile.readline(REQUEST_LINE_MAX + 1)
            if not self.raw_requestline:
                return
            if len(self.raw_requestline) > REQUEST_LINE_MAX:
                self.requestline = ""
                self.request_version = "HTTP/1.0"
                self.command = ""
                self._plain(414, "request line too long")
                return
            if not self.parse_request():
                return
            self.close_connection = True
            header_bytes = sum(len(k) + len(v) + 4 for k, v in self.headers.items())
            if len(self.headers) > HEADER_COUNT_MAX or header_bytes > HEADER_BYTES_MAX:
                self._plain(431, "request headers too large")
                return
            self._dispatch()
            self.wfile.flush()
        except (socket.timeout, TimeoutError, ConnectionError):
            self.close_connection = True
        except OSError:
            self.close_connection = True

    def _dispatch(self):
        config = self.server.config
        # Second line of defence: the server already drops other peers in verify_request,
        # before anything is read from the connection.
        if not peer_allowed(config.allow, self.client_address[0]):
            self._plain(403, "forbidden")
            return
        if self.command != "GET":
            self._plain(405, "method not allowed", {"Allow": "GET"})
            return
        path = urllib.parse.urlsplit(self.path).path
        if path == "/health":
            self._plain(200, "ok")
            return
        if path in ("/", "/index.html"):
            view = build_view(config)
            nonce = secrets.token_urlsafe(18)
            csp = (
                "default-src 'none'; script-src 'nonce-%s'; style-src 'nonce-%s'; "
                "connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'"
                % (nonce, nonce)
            )
            self._send(
                200,
                render_page(config.assets, view, nonce),
                "text/html; charset=utf-8",
                {"Content-Security-Policy": csp},
            )
            return
        if path == "/status.json":
            self._send(200, public_json(build_view(config), False), "application/json; charset=utf-8")
            return
        if path == "/diagnostics":
            self._send(200, public_json(build_view(config), True), "application/json; charset=utf-8")
            return
        self._plain(404, "not found")


def write_heartbeat(path, counter):
    """Replace the liveness counter file atomically: the decimal value and a newline go
    to a temporary file in the same directory (created with mode 0600, never following a
    symbolic link), which is then renamed over the target, so a reader sees the previous
    complete value or the new complete value, never a partial one. The temporary file is
    removed again if anything fails."""
    tmp = path + ".tmp"
    data = ("%d\n" % counter).encode("ascii")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        try:
            os.fchmod(fd, 0o600)
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
        finally:
            os.close(fd)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class StatusServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 16

    def __init__(self, address, config, heartbeat_file="", heartbeat_interval=HEARTBEAT_INTERVAL_S):
        self.config = config
        self._slots = threading.BoundedSemaphore(MAX_CONCURRENT)
        self.heartbeat_file = heartbeat_file or ""
        self.heartbeat_interval = heartbeat_interval
        self.heartbeat_counter = 0
        self._heartbeat_last = None
        self._heartbeat_failed = False
        super().__init__(address, Handler)

    def service_actions(self):
        """Called by serve_forever() on every pass of the accept loop (at least every
        poll interval), in the thread that accepts connections. The liveness counter is
        written from here, and nowhere else, so it stops advancing when the accept loop
        stops. A separate timer thread would keep running while the loop is hung."""
        self.heartbeat_beat()

    def heartbeat_beat(self, force=False):
        """Advance and atomically publish the liveness counter, at most once per
        heartbeat_interval seconds (always when force). Never raises: a failure to write
        is reported once on stderr (no path and no value) and the server keeps serving;
        the manager then sees a counter that no longer advances."""
        if not self.heartbeat_file:
            return False
        now = time.monotonic()
        if not force and self._heartbeat_last is not None and now - self._heartbeat_last < self.heartbeat_interval:
            return False
        self._heartbeat_last = now
        counter = self.heartbeat_counter + 1
        if counter >= HEARTBEAT_COUNTER_MAX:
            counter = 1
        try:
            write_heartbeat(self.heartbeat_file, counter)
        except OSError as err:
            if not self._heartbeat_failed:
                self._heartbeat_failed = True
                sys.stderr.write("status service: the liveness counter cannot be written (%s)\n" % (err.strerror or "error"))
                sys.stderr.flush()
            return False
        self.heartbeat_counter = counter
        self._heartbeat_failed = False
        return True

    def verify_request(self, request, client_address):
        """Drop a connection from any peer other than the allowed one before a single
        byte of it is read (no reply at all)."""
        return peer_allowed(self.config.allow, client_address[0])

    def process_request(self, request, client_address):
        """At most MAX_CONCURRENT connections are handled at once; a connection beyond
        that is closed at once instead of getting a thread."""
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


class StatusServer6(StatusServer):
    address_family = socket.AF_INET6  # supported by the server; the add-on's bind is IPv4


def env_default(name, fallback):
    value = os.environ.get(name, "")
    return value if value else fallback


def parse_args(argv):
    parser = argparse.ArgumentParser(description="HaLow access point status service (GET only)")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--bind", default=env_default("HALOW_STATUS_BIND", "172.30.32.1"))
    parser.add_argument(
        "--snapshot",
        default=env_default(
            "HALOW_STATUS_FILE",
            os.path.join(env_default("HALOW_RUN_DIR", "/run/halow"), "status.json"),
        ),
    )
    parser.add_argument("--allow-from", default=env_default("HALOW_STATUS_ALLOW_FROM", "172.30.32.2"))
    parser.add_argument(
        "--stale-after", type=int, default=int(env_default("HALOW_STATUS_STALE_AFTER_S", DEFAULT_STALE_AFTER_S))
    )
    parser.add_argument(
        "--heartbeat-file",
        default=env_default("HALOW_STATUS_HEARTBEAT_FILE", ""),
        help="liveness counter file (empty: none); the launcher always passes it",
    )
    parser.add_argument("--heartbeat-interval", type=float, default=HEARTBEAT_INTERVAL_S, help=argparse.SUPPRESS)
    parser.add_argument("--assets", default=ASSET_DIR, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def _stop(signum, frame):
    raise SystemExit(0)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        sys.stderr.write("status service: refusing to run as root\n")
        return 2
    if not 0 <= args.port <= 65535:
        sys.stderr.write("status service: invalid port\n")
        return 2
    if args.stale_after < 1:
        sys.stderr.write("status service: --stale-after must be at least 1 second\n")
        return 2
    if not 0.1 <= args.heartbeat_interval <= 10:
        sys.stderr.write("status service: --heartbeat-interval must be between 0.1 and 10 seconds\n")
        return 2
    try:
        allow = parse_allow(args.allow_from)
    except ValueError:
        sys.stderr.write("status service: invalid --allow-from value\n")
        return 2
    assets = Assets(args.assets)
    config = Config(args.snapshot, args.stale_after, allow, assets)
    server_class = StatusServer6 if ":" in args.bind else StatusServer
    try:
        server = server_class((args.bind, args.port), config, args.heartbeat_file, args.heartbeat_interval)
    except OSError as err:
        sys.stderr.write("status service: cannot listen on %s:%d (%s)\n" % (args.bind, args.port, err.strerror))
        return 1
    signal.signal(signal.SIGTERM, _stop)
    host, port = server.server_address[0], server.server_address[1]
    # The first value is published before the server announces itself and before the first
    # connection is accepted, so a counter left by an earlier run never stands in for this one.
    server.heartbeat_beat(force=True)
    sys.stderr.write("status service: listening on %s:%d\n" % (host, port))
    sys.stderr.flush()
    try:
        server.serve_forever(poll_interval=0.5)
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
