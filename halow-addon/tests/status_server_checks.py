#!/usr/bin/env python3
"""Checks of the status service over real HTTP (run by test_status_service.sh).

Usage: status_server_checks.py <status_server.py> <errors.sh> <work dir>

Each check prints "  ok: ..." or "  FAIL: ..."; the exit status is non-zero if any check
failed. Every server started here is stopped again, also when a check raises.

Optional end-to-end mode (environment): HALOW_E2E_SNAPSHOT names a snapshot written by
state.sh and HALOW_E2E_SECRET a string that must never be served.
"""

import atexit
import html.parser
import http.client
import ipaddress
import json
import os
import re
import selectors
import socket
import subprocess
import sys
import time

SERVER, ERRORS_SH, WORK = sys.argv[1], sys.argv[2], sys.argv[3]
COUNT = 0
FAILED = 0
PROCS = []
# Blocks that need a non-root user and loopback aliases are skipped with a note when the
# machine cannot run them; every skip is counted and printed in the summary line. A skip does
# not fail the run (set HALOW_REQUIRE_REAL_PROC=1 to make it fail). PLANNED_TOTAL is the
# number of checks of a full run (the check of the total included); REAL_BLOCK_CHECKS is the
# number in the real-process block.
SKIPPED_BLOCKS = 0
SKIPPED_CHECKS = 0
PLANNED_TOTAL = 253
REAL_BLOCK_CHECKS = 19


def skip_block(what, checks):
    global SKIPPED_BLOCKS, SKIPPED_CHECKS
    SKIPPED_BLOCKS += 1
    SKIPPED_CHECKS += checks
    print("  note: SKIPPED block (%d checks): %s" % (checks, what))

KEY_PP = "pass" + "phrase"
SECRET_VALUE = "Correct" + "HorseBattery42"
HEX64 = "cd" * 32


REMOVED_WORDING = ("development build", "not live-validated", "live-validated", "bandwidth validation",
                   "forwarding table", "neighbour", "add-on", "validated on the target", "not production-ready")


def no_removed_wording(page):
    """True if the page has none of the removed engineering wording and no bare 'HaLow'."""
    low = page.lower()
    if any(word in low for word in REMOVED_WORDING):
        return False
    return "HaLow" not in re.sub(r"Wi-Fi HaLow", "", page)


def check(cond, msg):
    global COUNT, FAILED
    COUNT += 1
    if cond:
        print("  ok: " + msg)
    else:
        FAILED += 1
        print("  FAIL: " + msg)
    return cond


def catalogue(kind, code):
    text = open(ERRORS_SH, encoding="utf-8").read()
    match = re.search(r"_HALOW_ERR_%s\[%s\]=\"([^\"]*)\"" % (kind, code), text)
    return match.group(1) if match else None


def stop_all():
    for proc in PROCS:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(5)


atexit.register(stop_all)


class Server:
    def __init__(self, snapshot, allow="127.0.0.1", stale_after=30, bind="127.0.0.1", extra=()):
        env = {k: v for k, v in os.environ.items() if not k.startswith("HALOW_")}
        cmd = [
            sys.executable, "-I", SERVER, "--port", "0", "--bind", bind,
            "--snapshot", snapshot, "--allow-from", allow, "--stale-after", str(stale_after),
        ] + list(extra)
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, env=env,
        )
        PROCS.append(self.proc)
        sel = selectors.DefaultSelector()
        sel.register(self.proc.stderr, selectors.EVENT_READ)
        data = b""
        end = time.time() + 15
        # The announcement may be preceded by a one-line report (an unwritable liveness
        # directory); read the raw descriptor so nothing waits in a buffer.
        while not re.search(rb"listening on .*:\d+\n", data) and time.time() < end:
            if not sel.select(timeout=max(0.1, end - time.time())):
                break
            chunk = os.read(self.proc.stderr.fileno(), 4096)
            if not chunk:
                break
            data += chunk
        sel.close()
        match = re.search(rb"listening on .*:(\d+)", data)
        if not match:
            raise RuntimeError("server did not start: %r" % data)
        self.port = int(match.group(1))

    def stop(self):
        self.proc.terminate()
        try:
            return self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return self.proc.wait(5)


def request(port, method, path, source=None, body=None, host="127.0.0.1"):
    conn = http.client.HTTPConnection(
        host, port, timeout=10, source_address=(source, 0) if source else None
    )
    try:
        headers = {}
        if body is not None:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read().decode("utf-8", "replace")
        return resp.status, {k.lower(): v for k, v in resp.getheaders()}, data
    finally:
        conn.close()


def raw_request(port, payload):
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    try:
        sock.sendall(payload)
        chunks = []
        while True:
            try:
                chunk = sock.recv(65536)
            except (ConnectionResetError, socket.timeout):
                break
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        sock.close()


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(obj, handle)
    os.replace(tmp, path)


def write_raw(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


def ip_entry(ip, source, conflict=False):
    return {"ip": ip, "source": source, "conflict": conflict}


def station(mac, online, kind, since, changed, ips=None, devices=None, omitted=0, source="hostapd"):
    return {"mac": mac, "online": online, "online_source": source, "kind": kind, "connected_since": since,
            "state_changed_at": changed, "ips": ips or [], "devices": devices or [], "devices_omitted": omitted}


def snapshot(**over):
    now = int(time.time())
    snap = {
        "schema": 2, "updated_at": now, "started_at": now - 50, "boot_id": "b-1",
        "overall": "operating", "attention": None,
        "advisory": {
            "code": "RADIO_AUTO_FALLBACK",
            "summary": catalogue("SUMMARY", "RADIO_AUTO_FALLBACK"),
            "action": catalogue("ACTION", "RADIO_AUTO_FALLBACK"),
            "since": now - 40,
        },
        "region": "AU",
        "radio": {
            "mode": "automatic",
            "requested": {"bandwidth_mhz": 2, "channel": None},
            "effective": {
                "frequency_khz": 922500, "channel": 41, "bandwidth_mhz": 2,
                "source": "fallback", "applied_at": now - 40,
                "validation": "implemented", "fallback_validated": False,
            },
            "last_applied": None,
        },
        "adapter": {"present": True, "interface": "wlan1"},
        "backend": {"applied": True, "bridge": "halow-br0", "subnet": "10.42.0.0/24", "gateway": "10.42.0.1"},
        "stations": [
            station("02:11:22:33:44:55", True, "ordinary", now - 2, now - 2, ips=[ip_entry("10.42.0.20", "dhcp")]),
            station("02:aa:bb:cc:dd:ee", False, "wds", None, now - 600),
        ],
        "diagnostics": {
            "op_class": "51", "s1g_scheme": "chanscheme-7", "prim_width": "primwidth-1",
            "prim_index": "primindex-0", "hostapd_conf_path": "/run/halow/hostapd.conf",
            "log_tail": ["started"],
        },
    }
    snap.update(over)
    return snap


class LinkCollector(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src", "action", "formaction", "poster", "data") and value is not None:
                self.urls.append(value)


def is_relative(url):
    return not (url.startswith("/") or url.startswith("\\") or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", url))


def main():
    os.makedirs(WORK, exist_ok=True)
    snap_path = os.path.join(WORK, "status.json")

    if os.environ.get("HALOW_E2E_SNAPSHOT"):
        return end_to_end(os.environ["HALOW_E2E_SNAPSHOT"], os.environ.get("HALOW_E2E_SECRET", ""))

    # --- module-level checks -------------------------------------------------------
    sys.dont_write_bytecode = True  # never leave a bytecode cache in the product tree
    sys.path.insert(0, os.path.dirname(SERVER))
    import status_server as srv  # noqa: E402

    # --- derived primary-channel values are never shown on the status page ----------------
    prim_snap = snapshot()
    prim_snap["overall"] = "operating"
    prim_snap["region"] = "AU"
    prim_snap["radio"] = {
        "mode": "manual",
        "requested": {"bandwidth_mhz": 8, "channel": 43},
        "effective": {"frequency_khz": 923500, "channel": 43, "bandwidth_mhz": 8, "source": "manual",
                      "applied_at": 1000, "validation": "implemented", "fallback_validated": None},
        "last_applied": None,
        # a stray object of the removed shape must not be rendered either
        "primary": {"op_class": 53, "channel": 43, "width_mhz": 8, "centre_khz": 923500,
                    "primary_bandwidth_mhz": 1, "primary_index": 0, "primary_1mhz_channel": 36,
                    "primary_1mhz_khz": 920000},
    }
    html_radio = srv._radio_section(prim_snap)
    check("In use now" in html_radio and "923.5 MHz" in html_radio,
          "the radio section still shows the values read back from the access point")
    check("Primary channel" not in html_radio and "Operating class" not in html_radio
          and "Centre frequency" not in html_radio and "920 MHz" not in html_radio,
          "the radio section shows no primary-channel rows (they are derived, not read from the radio)")
    check("primary" not in srv.empty_snapshot()["radio"], "the empty snapshot carries no primary object")

    check(srv.STATUS_STALE_SUMMARY == catalogue("SUMMARY", "STATUS_STALE"),
          "the server's STATUS_STALE summary equals the catalogue wording")
    check(srv.STATUS_STALE_ACTION == catalogue("ACTION", "STATUS_STALE"),
          "the server's STATUS_STALE action equals the catalogue wording")
    check(srv.redact_text("wpa_%s=%s rest" % (KEY_PP, SECRET_VALUE)) == "wpa_%s=[redacted]" % KEY_PP,
          "server redaction: assignment")
    red = srv.redact_text('{"wifi_%s": "%s", "ssid": "n"}' % (KEY_PP, SECRET_VALUE))
    check(SECRET_VALUE not in red and '"ssid": "n"' in red, "server redaction: JSON pair, structure kept")
    check(srv.redact_text("k " + HEX64) == "k [redacted]", "server redaction: 64-hex key")
    check(srv.redact_text("ok " + HEX64[:63]) == "ok " + HEX64[:63], "server redaction: 63 hex digits kept")
    red = srv.redact_obj({"wifi_" + KEY_PP: SECRET_VALUE, "nested": [{"Password": 12345678}], "x": "fine"})
    check(json.dumps(red).count(SECRET_VALUE) == 0 and red["nested"][0]["Password"] == "[redacted]"
          and red["x"] == "fine", "server redaction: secret-like keys replaced, other values kept")
    red = srv.redact_obj({"Pass" + "phrase": ["hunter2hunter2"], "wifi_psk": {"v": "abc-secret-value"},
                          "secret_ok": True, "psk_set": None, "ssid": ["n"]})
    check(red["Pass" + "phrase"] == "[redacted]" and red["wifi_psk"] == "[redacted]",
          "server redaction: a list or object under a secret-like key is replaced entirely")
    check("hunter2hunter2" not in json.dumps(red) and "abc-secret-value" not in json.dumps(red),
          "server redaction: no value under a secret-like key survives")
    check(red["secret_ok"] is True and red["psk_set"] is None and red["ssid"] == ["n"],
          "server redaction: booleans, null and ordinary lists are kept")
    check(srv.redact_text("SUPERVISOR_TOKEN=abc123def") == "SUPERVISOR_TOKEN=[redacted]",
          "server redaction: a token assignment")
    saved = os.environ.pop("HALOW_STATUS_STALE_AFTER_S", None)
    check(srv.parse_args(["--port", "1"]).stale_after == 90, "the default stale threshold is 90 s")
    if saved is not None:
        os.environ["HALOW_STATUS_STALE_AFTER_S"] = saved

    # --- page rendering of the validation state (no server needed) ------------------------
    def page_for(**over):
        return srv.render_main(srv.View(snapshot(**over), False, None))

    page = page_for()
    check("Bandwidth validation" not in page and "not live-validated" not in page and "Development build" not in page,
          "page: an implemented width carries no validation row, label or development note")
    radio = snapshot()["radio"]
    radio["effective"] = dict(radio["effective"], validation="live-validated", source="acs")
    page = page_for(radio=radio, advisory=None)
    check("Validated on the target device" not in page and "live-validated" not in page and "Automatic selection" in page,
          "page: a live-validated width shows no validation text either (the value is not rendered)")
    radio = snapshot()["radio"]
    radio["effective"] = dict(radio["effective"], validation=None)
    check("not live-validated" not in page_for(radio=radio) and "Bandwidth validation" not in page_for(radio=radio),
          "page: a missing validation value shows no validation text")
    radio = snapshot()["radio"]
    radio["effective"] = dict(radio["effective"], fallback_validated=None)
    check("Development build" not in page_for(radio=radio, advisory=None) and "not yet been validated" not in page_for(radio=radio, advisory=None),
          "page: a fallback without an explicit validated flag carries no development note")
    radio = snapshot()["radio"]
    radio["effective"] = dict(radio["effective"], fallback_validated=True, validation="live-validated")
    check("not yet been validated" not in page_for(radio=radio, advisory=None),
          "page: a validated fallback carries no unvalidated label")
    radio = snapshot()["radio"]
    radio["last_applied"] = dict(radio["effective"], validation="implemented")
    radio["effective"] = None
    page = page_for(overall="attention", radio=radio, advisory=None)
    check("Last values used" in page and "Active since" in page and "not live-validated" not in page,
          "page: last used values show when they were active, with no validation label")
    radio = snapshot()["radio"]
    radio["effective"] = None
    page = page_for(overall="operating", radio=radio, advisory=None)
    check("active radio values cannot be read right now" in page and "has not started" not in page,
          "page: operating without readable radio values says so and shows your settings only")
    check("Your settings" in page and "Bandwidth setting" in page, "page: your settings stay visible")
    reps = [
        page_for(),
        page_for(radio=dict(snapshot()["radio"], effective=dict(snapshot()["radio"]["effective"], validation="live-validated", source="acs")), advisory=None),
        page_for(overall="attention", radio=dict(snapshot()["radio"], effective=None, last_applied=snapshot()["radio"]["effective"]), advisory=None),
        page_for(overall="operating", radio=dict(snapshot()["radio"], effective=None), advisory=None),
        page_for(stations=[station("02:00:00:00:00:30", True, "wds", 1700000000, 1700000000, ips=[ip_entry("192.0.2.80", "dhcp+neighbour", True)],
                                   devices=[{"mac": "02:00:00:00:01:01", "ips": [ip_entry("192.0.2.59", "neighbour")]}, {"mac": "02:00:00:00:01:02", "ips": []}]),
                           station("02:00:00:00:00:31", False, "wds", None, 1700000000),
                           station("02:00:00:00:00:32", False, "ordinary", None, 1700000000, source="log")]),
        srv.render_main(srv.View(srv.empty_snapshot(), False, None)),
    ]
    check(all(no_removed_wording(r) for r in reps),
          "page: representative snapshots never show 'Development build', 'not live-validated', 'Bandwidth validation', "
          "'forwarding table', 'neighbour', 'add-on' or a bare 'HaLow'")

    # --- connected devices: station rows, downstream devices, times (no server needed) ----
    T0 = 1700000000  # 2023-11-14 22:13:20 UTC
    ts = srv.fmt_time(T0)
    ts_off = srv.fmt_time(T0 + 500)
    D1, D2, D3 = "02:00:00:00:01:01", "02:00:00:00:01:02", "02:00:00:00:01:03"
    page = page_for(stations=[station("02:00:00:00:00:01", True, "ordinary", T0, T0 + 5, ips=[ip_entry("192.0.2.51", "dhcp")])])
    check("Connected since %s" % ts in page and "Last change" not in page,
          "devices: an online station shows 'Connected since' (the time of its latest connection)")
    check("192.0.2.51" in page and "DHCP lease" not in page and "neighbour" not in page and "Not available" not in page,
          "devices: an ordinary station shows its address and names no internal source")
    check("Last seen" not in page and "last seen" not in page.lower(), "devices: no 'Last seen' wording anywhere")
    check("not whether a device is sending data" in page,
          "devices: the page says online and offline are not activity tracking")
    page = page_for(stations=[station("02:00:00:00:00:01", False, "ordinary", None, T0 + 500)])
    check("Last change: %s" % ts_off in page and "Connected since" not in page,
          "devices: an offline station shows the time of its last connection change, not 'Connected since'")
    check("<li>Not available</li>" in page and "Unknown" not in page, "devices: an ordinary station with no mapping shows Not available")
    page = page_for(stations=[station("02:00:00:00:00:01", False, "ordinary", T0, T0 + 500)])
    check("Last change: %s" % ts_off in page and "Connected since" not in page,
          "devices: an offline station never shows 'Connected since', even if a stale connected-since value is present")
    page = page_for(stations=[station("02:00:00:00:00:01", True, "ordinary", None, T0 + 500)])
    check("Last change: %s" % ts_off in page and "Connected since" not in page,
          "devices: an online station without a connected-since time falls back to the last connection change")
    page = page_for(stations=[station("02:00:00:00:00:01", True, "ordinary", None, None)])
    check("Last change: unknown" in page, "devices: a station with no time at all shows unknown")
    page = page_for(stations=[station("02:00:00:00:00:30", True, "wds", T0, T0, ips=[ip_entry("192.0.2.80", "dhcp")], devices=[
        {"mac": D1, "ips": [ip_entry("192.0.2.59", "dhcp+neighbour")]},
        {"mac": D2, "ips": []},
        {"mac": D3, "ips": [ip_entry("192.0.2.60", "dhcp", True), ip_entry("192.0.2.61", "neighbour")]},
    ], omitted=3)])
    check(all(x in page for x in (D1, D2, D3, "192.0.2.59", "192.0.2.60", "192.0.2.61")),
          "devices: every downstream device and every address is shown")
    check("%s</span>: IP address not available" % D2 in page, "devices: a device with no mapping is shown with its address unknown")
    check("This device: <span class=\"mono\">192.0.2.80</span>" in page, "devices: the bridged station's own address is labelled as such")
    check("DHCP lease" not in page and "neighbour" not in page and "192.0.2.59" in page and "192.0.2.61" in page,
          "devices: addresses carry no internal source label")
    check(page.count("Another device may also use this address.") == 1,
          "devices: a conflicting address carries the plain conflict marker, and only that one")
    check("3 more devices not shown." in page, "devices: devices left out of the snapshot are counted on the page")
    check("Connects other devices" in page and "No other devices" not in page,
          "devices: a bridged station is labelled, and with devices behind it is not described as empty")
    check(page.count('<tr><td data-label="Device">') == 1, "devices: one primary row for the station however many devices are behind it")
    row = page[page.index('<tr><td data-label="Device">'):page.index('</tr>', page.index('<tr><td data-label="Device">'))]
    check([m for m in re.findall(r'<td data-label="([^"]+)"', row)] == ["Device", "Status", "Time", "IP address"],
          "devices: each row cell carries its label (Device, Status, Time, IP address) so a narrow screen can stack the record")
    check(re.findall(r'<th scope="col">([^<]+)</th>', page) == ["Device (MAC address)", "Status", "Time", "IP address"] and "<thead>" in page,
          "devices: the semantic table header stays in the page for the desktop layout and for assistive technology")
    css_text = open(os.path.join(os.path.dirname(SERVER), "page.css"), encoding="utf-8").read()
    narrow = css_text[css_text.index("@media (max-width: 520px)"):]
    check("td::before" in narrow and "attr(data-label)" in narrow and "display: block" in narrow and "thead" in narrow,
          "devices: the existing narrow-width breakpoint stacks each device row with its labels")
    check("td::before" not in css_text[:css_text.index("@media (max-width: 520px)")],
          "devices: the stacked layout applies only inside the narrow-width breakpoint (desktop table unchanged)")
    page = page_for(stations=[station("02:00:00:00:00:30", True, "wds", T0, T0, devices=[{"mac": D1, "ips": [ip_entry("192.0.2.59", "dhcp")]}])])
    check("IP address not available" not in page and "Unknown" not in page,
          "devices: 'not available' is not shown for a device that has a mapping")
    page = page_for(stations=[station("02:00:00:00:00:30", True, "wds", T0, T0)])
    check("No other devices are connected through it right now." in page and "IP address not available" not in page
          and "has been seen" not in page,
          "devices: zero devices behind an online bridged station is said plainly (not that none was ever seen), not shown as an unavailable address")
    page = page_for(stations=[station("02:00:00:00:00:30", False, "wds", None, T0)])
    check("No other devices listed." in page and "No other devices are connected" not in page and "forwarding table" not in page,
          "devices: an empty list for an offline bridged station claims nothing about devices being absent or never seen")
    page = page_for(stations=[station("02:00:00:00:00:01", True, "ordinary", T0, T0, source="log")])
    check("status estimated" in page and "connection log" not in page,
          "devices: a station whose online state was not confirmed by the access point says the status is estimated")
    check("Online and Offline show the connection to the access point" in page,
          "devices: the note says what Online and Offline mean")
    page = page_for(stations=[station("02:00:00:00:00:30", False, "wds", None, T0, devices=[{"mac": D1, "ips": []}])])
    check("Offline" in page and D1 in page and "No other devices listed" not in page,
          "devices: an Offline row that still has a bridge port lists its devices (no false 'none' text)")
    page = page_for(stations=[station("02:00:00:00:00:01", True, "ordinary", T0, T0)])
    check("<br><span class=\"meta\">status estimated</span>" not in page,
          "devices: a station whose state came from hostapd carries no such label")
    page = page_for(stations=[
        station("02:00:00:00:00:01", True, "ordinary", T0, T0),
        station("02:00:00:00:00:02", True, "wds", T0, T0),
        station("02:00:00:00:00:03", False, "wds", None, T0),
    ])
    check(page.count('<tr><td data-label="Device">') == 3, "devices: one primary row per station, in the given order")
    odd = [
        {"mac": 5, "online": "yes", "kind": [], "connected_since": "soon", "state_changed_at": [], "ips": "x",
         "devices": "y", "devices_omitted": {}},
        {"mac": "02:00:00:00:00:09", "online": True, "kind": "wds", "ips": [None, 3, {"ip": 4}, {"ip": ""}, "z"],
         "devices": [None, "d", {"mac": None, "ips": None}, {"mac": D1, "ips": [{"ip": "192.0.2.1", "source": "nope"}]},
                    {"mac": D2, "ips": [{"ip": "192.0.2.2", "source": ["x"]}]}],
         "devices_omitted": -4},
        "not an object",
    ]
    try:
        page = page_for(stations=odd)
        rendered = True
    except Exception as exc:  # the page must always render
        rendered = False
        print("  (render error: %r)" % (exc,))
    check(rendered and "192.0.2.1" in page and D1 in page, "devices: malformed station data never breaks the page")
    evil = station('"><script>alert(1)</script>', True, "wds", T0, T0, ips=[ip_entry('"><b>x</b>', '"><i>y</i>', True)], devices=[
        {"mac": "<img src=x onerror=alert(2)>", "ips": [ip_entry("<u onmouseover=alert(3)>", "dhcp")]}], omitted="<q>")
    page = page_for(stations=[evil])
    check("<script>alert" not in page and "<img src=x" not in page and "<b>x" not in page and "<u onmouseover" not in page
          and "<i>y" not in page and "<q>" not in page,
          "devices: hostile station, device and address values are never injected as markup")
    check("&lt;img src=x onerror=alert(2)&gt;" in page and "&lt;u onmouseover=alert(3)&gt;" in page,
          "devices: hostile values are shown escaped")
    check("onerror=alert(2)" not in page.replace("&lt;img src=x onerror=alert(2)&gt;", ""),
          "devices: no unescaped attribute text is left over")

    # --- a normal operating snapshot with the fallback advisory -------------------------
    write_json(snap_path, snapshot())
    server = Server(snap_path)
    port = server.port

    status, headers, page = request(port, "GET", "/")
    check(status == 200 and headers.get("content-type", "").startswith("text/html"), "GET / serves the page")
    check("Operating" in page, "page shows the overall state")
    check("The access point is running and devices can connect." in page, "operating shows its state line")
    check("The access point is starting." not in page, "operating does not show the starting line")
    check("Backup channel (automatic selection did not complete)" in page, "page shows the channel source in plain words")
    check('class="banner banner-advisory"' in page and "Using a backup channel" in page,
          "page shows the backup channel advisory banner")
    check(catalogue("SUMMARY", "RADIO_AUTO_FALLBACK") in page, "page carries the catalogue advisory text")
    check("success" not in page.lower(), "the advisory is never worded as a success")
    check("922.5 MHz" in page and ">41<" in page and "2 MHz" in page,
          "page shows the effective frequency, channel and bandwidth")
    check("Bandwidth setting" in page and "Automatic (chosen each time the app starts)" in page,
          "your settings are labelled as settings")
    check("not yet been validated" not in page and "Development build" not in page,
          "a fallback channel is not labelled with development notes")
    check(no_removed_wording(page), "the served page has none of the removed engineering wording and no bare 'HaLow'")
    check("frequency and bandwidth shown under" in page, "page says how clients must be matched")
    check("AU" in page and "Wi-Fi HaLow USB Network Adapter" in page and "Detected" in page and "Networking" in page and "Active" in page,
          "region, adapter and networking shown")
    check("02:11:22:33:44:55" in page and "10.42.0.20" in page and "Online" in page, "online station listed")
    check("Offline" in page and "No other devices listed." in page,
          "offline WDS station with nothing behind it listed")
    check("Development build" not in page and "not production-ready" not in page, "the footer carries no development-build notice")
    # The footer says the diagnostics have the passphrase removed; that phrase is the only allowed mention.
    lower = page.lower().replace("(passphrase removed; includes device addresses)", "")
    for word in ("operating class", "op_class", "51<", "chanscheme", "channelisation", "primwidth", "primindex",
                 "primary", "hostapd", KEY_PP, "wlan1", "stopped"):
        check(word not in lower, "page does not show '%s'" % word)
    check("prefers-color-scheme: dark" in page and "color-scheme" in page, "light and dark colour schemes")
    check('<meta name="viewport"' in page, "responsive viewport")
    check('<noscript><meta http-equiv="refresh"' in page, "page refreshes itself without JavaScript")
    csp = headers.get("content-security-policy", "")
    nonce = re.search(r"'nonce-([^']+)'", csp)
    check(nonce is not None and ('<script nonce="%s">' % nonce.group(1)) in page,
          "a per-response script nonce in the CSP")
    check("default-src 'none'" in csp, "CSP denies everything else")
    check(headers.get("cache-control") == "no-store", "no caching")

    collector = LinkCollector()
    collector.feed(page)
    check(len(collector.urls) >= 1 and all(is_relative(u) for u in collector.urls),
          "every link in the page is relative: %s" % collector.urls)
    fetches = re.findall(r"fetch\(\s*[\"']([^\"']+)[\"']", page)
    check(fetches == ["status.json"] and all(is_relative(u) for u in fetches), "the page polls status.json relatively")
    check("://" not in page and "@import" not in page and "url(" not in page, "no external resources")
    check("location.href" in page and "setInterval" in page, "the script polls periodically")

    status, headers, body = request(port, "GET", "/status.json")
    data = json.loads(body)
    check(status == 200 and headers.get("content-type", "").startswith("application/json"), "GET /status.json")
    check("diagnostics" not in data, "status.json has no diagnostics")
    check(data.get("stale") is False and data.get("overall") == "operating", "status.json fresh and operating")
    check(data["radio"]["effective"]["source"] == "fallback", "status.json carries the channel source")
    st0 = data["stations"][0]
    check(data["schema"] == 2 and st0["kind"] == "ordinary" and st0["ips"][0]["ip"] == "10.42.0.20"
          and st0["devices"] == [] and "last_seen" not in st0 and "ip" not in st0,
          "status.json carries schema 2 stations: own addresses and devices, no last_seen, no single ip")
    status, _, body = request(port, "GET", "/status.json?cache=1")
    check(status == 200, "query strings are ignored")
    status, _, body = request(port, "GET", "/diagnostics")
    diag = json.loads(body)
    check(status == 200 and diag.get("diagnostics", {}).get("op_class") == "51" and diag.get("stale") is False,
          "GET /diagnostics includes the diagnostics")
    check(diag["stations"] == data["stations"],
          "GET /diagnostics carries the same station and device data as status.json (documented: review before sharing)")
    status, headers, body = request(port, "GET", "/health")
    check(status == 200 and body.strip() == "ok", "GET /health")
    status, _, _ = request(port, "GET", "/nope")
    check(status == 404, "unknown path is 404")
    status, _, _ = request(port, "GET", "/../etc/passwd")
    check(status == 404, "path traversal is 404")

    for method in ("POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"):
        for path in ("/", "/status.json", "/health"):
            body = '{"x": 1}' if method in ("POST", "PUT", "PATCH") else None
            status, headers, _ = request(port, method, path, body=body)
            check(status == 405 and headers.get("allow") == "GET", "%s %s is 405 with Allow: GET" % (method, path))
    before = open(snap_path, "rb").read()
    request(port, "POST", "/status.json", body=json.dumps({"overall": "attention"}))
    check(open(snap_path, "rb").read() == before, "no request changes the snapshot")

    # oversized request line and too many headers
    reply = raw_request(port, b"GET /" + b"a" * 6000 + b" HTTP/1.0\r\n\r\n")
    check(reply == b"" or reply.startswith(b"HTTP/1.0 414"), "an oversized request line is refused")
    many = b"".join(b"X-H%d: v\r\n" % i for i in range(60))
    reply = raw_request(port, b"GET / HTTP/1.0\r\n" + many + b"\r\n")
    check(reply.startswith(b"HTTP/1.0 431"), "too many headers are refused")
    started = time.time()
    reply = raw_request(port, b"GET / HTTP/1.0\r\n")
    check(time.time() - started < 9, "an idle client is dropped after a short timeout")
    status, _, _ = request(port, "GET", "/health")
    check(status == 200, "the server still answers after bad clients")

    # --- the snapshot is re-read on every request ---------------------------------------
    att = {
        "code": "NO_ADAPTER", "summary": catalogue("SUMMARY", "NO_ADAPTER"),
        "action": catalogue("ACTION", "NO_ADAPTER"),
        "detail": '"><script>alert(1)</script><img src=x onerror=alert(2)>',
        "since": int(time.time()) - 30, "host_clean": True, "retryable": True,
    }
    hostile_station = station("<img src=x onerror=alert(3)>", True, "wds", int(time.time()), int(time.time()),
                              ips=[ip_entry("<b>bold</b>", "<i>src</i>", True)],
                              devices=[{"mac": "<script>alert(5)</script>", "ips": [ip_entry("<u>u</u>", "dhcp", "<s>x</s>")]}],
                              omitted="<q>")
    write_json(snap_path, snapshot(overall="attention", attention=att, advisory=None,
                                   region="<i>AU</i>", stations=[hostile_station]))
    status, _, page = request(port, "GET", "/")
    check("Attention required" in page and catalogue("SUMMARY", "NO_ADAPTER") in page,
          "a changed snapshot is served immediately (no stale cache)")
    check(catalogue("ACTION", "NO_ADAPTER") in page and "NO_ADAPTER" in page, "attention entry: action and code")
    check("The access point is running and devices can connect." not in page
          and "The access point is starting." not in page, "attention shows no state line")
    check("The app has undone its changes to the system." in page, "host_clean shown in plain words")
    check("<script>alert" not in page and "<img src=x" not in page and "<b>bold" not in page and "<i>AU" not in page,
          "hostile values are not injected as HTML")
    check("&lt;script&gt;alert(1)&lt;/script&gt;" in page and "&lt;img src=x onerror=alert(3)&gt;" in page,
          "hostile values are shown escaped")
    check(page.count("<script") == 1, "the only script element is the page's own")
    check('class="banner banner-advisory"' not in page, "no advisory banner without an advisory")

    # last applied values while the AP is down
    radio = snapshot()["radio"]
    radio["last_applied"] = dict(radio["effective"], source="acs", applied_at=1700000000)
    radio["effective"] = None
    write_json(snap_path, snapshot(overall="attention", attention=dict(att, code="AP_DIED", detail=""),
                                   advisory=None, radio=radio))
    status, _, page = request(port, "GET", "/")
    check("Last values used (access point not running), as of 2023-11-14 22:13:20 UTC" in page,
          "AP down: last applied values labelled with when")
    check("Automatic selection" in page, "ACS source in plain words")
    radio["last_applied"] = None
    write_json(snap_path, snapshot(overall="starting", advisory=None, radio=radio))
    status, _, page = request(port, "GET", "/")
    check("Starting" in page and "Not available yet" in page, "starting with no radio values yet")
    check("The access point is starting. This page updates by itself." in page
          and "The access point is running and devices can connect." not in page, "starting shows its state line")

    # --- stale, malformed and missing snapshots ------------------------------------------
    write_json(snap_path, snapshot(updated_at=int(time.time()) - 100))
    status, _, body = request(port, "GET", "/status.json")
    data = json.loads(body)
    check(data["stale"] is True and data["stale_reason"] == "old", "an old heartbeat is stale")
    status, _, page = request(port, "GET", "/")
    check("Status may be out of date" in page and catalogue("SUMMARY", "STATUS_STALE") in page and "STATUS_STALE" in page,
          "the page says the status is stale with the catalogue wording")
    check(catalogue("ACTION", "STATUS_STALE") == "Restart the app. If the message stays, check the app's Log tab."
          and re.search(r"check the app(&#x27;|&#39;|')s Log tab\.", page) is not None,
          "the stale page shows the Log tab action, identical to the catalogue")
    check("The access point is running and devices can connect." not in page, "a stale page shows no state line")
    status, _, body = request(port, "GET", "/health")
    check(status == 200 and body.strip() == "ok", "/health is unaffected by a stale snapshot")

    good = json.dumps(snapshot()).encode("utf-8")
    for label, data_bytes in (("truncated", good[: len(good) // 2]), ("garbage", b"{"),
                              ("wrong schema", json.dumps(snapshot(schema=3)).encode()),
                              ("old schema 1", json.dumps(snapshot(schema=1)).encode()),
                              ("not an object", b"[1,2]"), ("invalid UTF-8", b"\xff\xfe{}"),
                              ("no heartbeat", json.dumps(snapshot(updated_at="soon")).encode())):
        write_raw(snap_path, data_bytes)
        status, _, body = request(port, "GET", "/status.json")
        data = json.loads(body)
        check(status == 200 and data["stale"] is True and data["stale_reason"] == "unreadable",
              "%s snapshot is reported stale (unreadable)" % label)
        status, _, page = request(port, "GET", "/")
        check(status == 200 and "Status may be out of date" in page, "%s snapshot: page still renders, stale" % label)
        status, _, _ = request(port, "GET", "/health")
        check(status == 200, "%s snapshot: /health still 200" % label)

    # --- redaction on output, whatever the snapshot contains ----------------------------
    leaky = snapshot(
        overall="attention",
        attention=dict(att, detail="wpa_%s=%s" % (KEY_PP, SECRET_VALUE)),
        region="AU %s: %s" % (KEY_PP, SECRET_VALUE),
        stations=[dict(hostile_station, mac='{"%s":"%s"}' % (KEY_PP, SECRET_VALUE),
                         devices=[{"mac": "psk=" + SECRET_VALUE, "ips": [ip_entry("%s: %s" % (KEY_PP, SECRET_VALUE), "dhcp")]}])],
    )
    leaky["diagnostics"] = {"wifi_" + KEY_PP: SECRET_VALUE, "conf": "psk=" + SECRET_VALUE,
                            "key": HEX64, "log_tail": ["hostapd: wpa_%s=%s" % (KEY_PP, SECRET_VALUE)]}
    write_json(snap_path, leaky)
    for path in ("/", "/status.json", "/diagnostics"):
        status, _, body = request(port, "GET", path)
        check(status == 200 and SECRET_VALUE not in body and HEX64 not in body,
              "%s never serves a secret that leaked into the snapshot" % path)

    code = server.stop()
    check(code == 0, "the server stops cleanly on SIGTERM")

    # --- peer restriction -----------------------------------------------------------------
    write_json(snap_path, snapshot())
    server = Server(snap_path, allow="127.0.0.2")
    for method, path in (("GET", "/"), ("GET", "/status.json"), ("GET", "/diagnostics"),
                         ("GET", "/health"), ("POST", "/")):
        reply = raw_request(server.port, b"%s %s HTTP/1.0\r\n\r\n" % (method.encode(), path.encode()))
        check(reply == b"", "%s %s from a disallowed peer: connection closed, nothing served" % (method, path))
    # A request that would be refused while parsing (too many headers -> 431) proves the
    # peer is checked before anything is parsed: a disallowed peer gets no reply at all.
    many = b"".join(b"X-H%d: v\r\n" % i for i in range(60))
    reply = raw_request(server.port, b"GET / HTTP/1.0\r\n" + many + b"\r\n")
    check(reply == b"", "a disallowed peer is dropped before its request is parsed (no 431)")
    reply = raw_request(server.port, b"GET /" + b"a" * 6000 + b" HTTP/1.0\r\n\r\n")
    check(reply == b"", "a disallowed peer is dropped before its request line is read (no 414)")
    try:
        status, _, _ = request(server.port, "GET", "/health", source="127.0.0.2")
        check(status == 200, "the allowed peer is served")
    except OSError as err:
        check(False, "could not connect from 127.0.0.2: %s" % err)
    server.stop()

    # --- bounded concurrency ---------------------------------------------------------------
    check(srv.MAX_CONCURRENT == 16, "at most 16 connections are handled at once")
    server = Server(snap_path)
    idle = []
    try:
        for _ in range(40):
            sock = socket.create_connection(("127.0.0.1", server.port), timeout=10)
            sock.sendall(b"G")
            idle.append(sock)
        time.sleep(1.0)
        tasks = len(os.listdir("/proc/%d/task" % server.proc.pid))
        check(tasks <= srv.MAX_CONCURRENT + 2,
              "40 idle connections do not get 40 threads (%d threads)" % tasks)
        dropped = 0
        for sock in idle:
            sock.settimeout(0.2)
            try:
                if sock.recv(1) == b"":
                    dropped += 1
            except socket.timeout:
                pass
            except OSError:
                dropped += 1
        check(dropped >= 40 - srv.MAX_CONCURRENT, "connections beyond the limit are closed at once (%d)" % dropped)
    finally:
        for sock in idle:
            sock.close()
    time.sleep(0.5)
    status, _, body = request(server.port, "GET", "/health")
    check(status == 200 and body.strip() == "ok", "the server answers again once the idle connections are gone")
    server.stop()

    # --- missing snapshot: starting, then stale ------------------------------------------
    missing = os.path.join(WORK, "absent", "status.json")
    server = Server(missing, stale_after=1)
    status, _, body = request(server.port, "GET", "/status.json")
    data = json.loads(body)
    check(data["stale"] is False and data["overall"] == "starting", "missing snapshot right after start: starting")
    status, _, page = request(server.port, "GET", "/")
    check("Starting" in page and "Status may be out of date" not in page, "page shows starting while the manager starts")
    time.sleep(1.6)
    status, _, body = request(server.port, "GET", "/status.json")
    data = json.loads(body)
    check(data["stale"] is True and data["stale_reason"] == "missing", "a snapshot that never appears becomes stale")
    status, _, page = request(server.port, "GET", "/")
    check("Status may be out of date" in page and "Attention required" in page, "page reports the stale status")
    status, _, body = request(server.port, "GET", "/health")
    check(status == 200 and body.strip() == "ok", "/health stays ok without a snapshot")
    server.stop()

    # --- refused arguments -----------------------------------------------------------------
    result = subprocess.run([sys.executable, "-I", SERVER, "--port", "0", "--bind", "127.0.0.1",
                             "--snapshot", snap_path, "--allow-from", "not-an-address"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20)
    check(result.returncode == 2, "an invalid --allow-from is refused")
    result = subprocess.run([sys.executable, "-I", SERVER, "--bind", "127.0.0.1"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    check(result.returncode != 0, "a port is required (never guessed)")
    liveness_checks(srv, snap_path)
    return 0


def read_counter(path):
    """The counter file's value as an int, None when absent or not exactly digits+newline."""
    try:
        with open(path, "rb") as handle:
            data = handle.read(64)
    except OSError:
        return None
    return int(data[:-1]) if re.fullmatch(rb"[0-9]{1,20}\n", data) else None


def wait_for(cond, limit=8.0, step=0.05):
    end = time.time() + limit
    while time.time() < end:
        value = cond()
        if value:
            return value
        time.sleep(step)
    return cond()


def can_bind(address):
    probe = socket.socket()
    try:
        probe.bind((address, 0))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def raw_request_from(port, payload, source, host):
    """Send payload from a chosen source address (None: let the kernel choose); the reply bytes."""
    sock = socket.socket()
    sock.settimeout(10)
    try:
        if source:
            sock.bind((source, 0))
        sock.connect((host, port))
        sock.sendall(payload)
        chunks = []
        while True:
            try:
                chunk = sock.recv(65536)
            except (ConnectionResetError, socket.timeout):
                break
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    except OSError:
        return b""
    finally:
        sock.close()


def liveness_checks(srv, snap_path):
    """The default allow list, the peer filter on a real server, and the liveness counter."""
    import contextlib
    import io
    import signal
    import stat
    import threading

    work = os.path.join(WORK, "liveness")
    os.makedirs(work, exist_ok=True)
    is_root = hasattr(os, "geteuid") and os.geteuid() == 0

    print("-- the default peer allow list is exactly the Ingress proxy --")
    saved = {k: v for k, v in os.environ.items() if k.startswith("HALOW_")}
    for key in saved:
        del os.environ[key]
    try:
        args = srv.parse_args(["--port", "1"])
    finally:
        os.environ.update(saved)
    check(args.allow_from == "172.30.32.2", "the default --allow-from is exactly 172.30.32.2")
    check(args.bind == "172.30.32.1", "the default --bind is the bridge gateway 172.30.32.1")
    check(args.heartbeat_file == "", "no liveness file unless the launcher passes one")
    default_allow = srv.parse_allow(args.allow_from)
    check(default_allow == {ipaddress.ip_address("172.30.32.2")}, "the parsed default allow set holds exactly one address: 172.30.32.2")
    for peer, want in (("172.30.32.2", True), ("172.30.32.1", False), ("127.0.0.1", False), ("127.0.0.2", False),
                       ("172.30.32.3", False), ("0.0.0.0", False), ("::1", False), ("::ffff:172.30.32.1", False),
                       ("::ffff:127.0.0.1", False), ("172.30.32.2%eth0", True), ("", False), ("garbage", False)):
        check(srv.peer_allowed(default_allow, peer) is want, "peer_allowed(default, %r) is %s" % (peer, want))
    config = srv.Config(snap_path, 30, default_allow, srv.Assets(srv.ASSET_DIR))
    default_server = srv.StatusServer(("127.0.0.1", 0), config)
    try:
        for peer, want in (("172.30.32.2", True), ("172.30.32.1", False), ("127.0.0.1", False)):
            check(default_server.verify_request(None, (peer, 40000)) is want,
                  "verify_request with the default allow list: %s -> %s" % (peer, "served" if want else "dropped"))
        check(default_server.heartbeat_beat() is False and default_server.heartbeat_file == "",
              "a server without a liveness file writes nothing")
    finally:
        default_server.server_close()

    print("-- the liveness counter file: atomic, private, clean --")
    hb_dir = os.path.join(work, "hb")
    os.makedirs(hb_dir, mode=0o700, exist_ok=True)
    os.chmod(hb_dir, 0o700)
    hb = os.path.join(hb_dir, "heartbeat")
    old_umask = os.umask(0o000)
    try:
        srv.write_heartbeat(hb, 1)
    finally:
        os.umask(old_umask)
    check(open(hb, "rb").read() == b"1\n", "the file holds the decimal counter and one newline")
    check(stat.S_IMODE(os.stat(hb).st_mode) == 0o600, "the counter file is mode 0600 even with a permissive umask")
    check(os.listdir(hb_dir) == ["heartbeat"], "no temporary file is left after a write")
    srv.write_heartbeat(hb, 987654321)
    check(read_counter(hb) == 987654321, "a later value replaces the earlier one")
    # A stale temporary file with wide permissions is not trusted: the result is 0600.
    tmp = hb + ".tmp"
    with open(tmp, "w") as handle:
        handle.write("stale")
    os.chmod(tmp, 0o666)
    srv.write_heartbeat(hb, 5)
    check(stat.S_IMODE(os.stat(hb).st_mode) == 0o600 and read_counter(hb) == 5 and not os.path.exists(tmp),
          "a stale temporary file is replaced; the result is 0600 and no temporary file remains")
    # A symbolic link in the temporary name is never followed.
    victim = os.path.join(work, "victim")
    with open(victim, "w") as handle:
        handle.write("untouched")
    os.symlink(victim, tmp)
    try:
        srv.write_heartbeat(hb, 6)
        raised = False
    except OSError:
        raised = True
    check(raised and open(victim).read() == "untouched" and read_counter(hb) == 5,
          "a symbolic link planted as the temporary name is refused and never written through")
    os.unlink(tmp)
    # The target cannot be replaced (it is a directory): the error is raised and the temporary file removed.
    bad_target = os.path.join(hb_dir, "bad")
    os.mkdir(bad_target)
    try:
        srv.write_heartbeat(bad_target, 7)
        raised = False
    except OSError:
        raised = True
    check(raised and not os.path.exists(bad_target + ".tmp"), "a failed replace raises and removes its temporary file")
    os.rmdir(bad_target)
    # No partial file is ever visible to a concurrent reader.
    stop_reader = threading.Event()
    seen = {"bad": 0, "reads": 0, "backwards": 0}

    def reader():
        last = 0
        while not stop_reader.is_set():
            try:
                with open(hb, "rb") as handle:
                    data = handle.read()
            except FileNotFoundError:
                seen["bad"] += 1
                continue
            seen["reads"] += 1
            if not re.fullmatch(rb"[0-9]{1,20}\n", data):
                seen["bad"] += 1
            else:
                value = int(data)
                if value < last:
                    seen["backwards"] += 1
                last = value

    thread = threading.Thread(target=reader)
    thread.start()
    try:
        for value in range(100, 2100):
            srv.write_heartbeat(hb, value * 100000007)
    finally:
        stop_reader.set()
        thread.join(10)
    check(seen["reads"] > 50 and seen["bad"] == 0, "a concurrent reader never sees a missing or partial file (%d reads)" % seen["reads"])
    check(seen["backwards"] == 0, "a concurrent reader never sees the counter go backwards while it is written upwards")

    print("-- the server publishes it from its accept loop --")
    hb2 = os.path.join(work, "hb2", "heartbeat")
    os.makedirs(os.path.dirname(hb2), mode=0o700, exist_ok=True)
    server = srv.StatusServer(("127.0.0.1", 0), config, hb2, 1000)
    try:
        check(server.heartbeat_beat(force=True) is True and read_counter(hb2) == 1, "the first value is 1")
        check(server.heartbeat_beat() is False and read_counter(hb2) == 1, "a second call inside the interval writes nothing")
        server.heartbeat_interval = 0
        check(server.heartbeat_beat() is True and read_counter(hb2) == 2, "after the interval the counter advances by one")
        server.heartbeat_counter = srv.HEARTBEAT_COUNTER_MAX - 1
        server.heartbeat_beat()
        check(read_counter(hb2) == 1, "the counter wraps to 1 before it could exceed 20 digits")
    finally:
        server.server_close()
    again = srv.StatusServer(("127.0.0.1", 0), config, hb2, 0)
    try:
        again.heartbeat_beat(force=True)
        check(read_counter(hb2) == 1, "a new server process starts again at 1 (a reset the manager must read as a change)")
    finally:
        again.server_close()

    # A status child that cannot write: reported once, no path, no value; the counter does not advance.
    gone = os.path.join(work, "no-such-dir", "heartbeat")
    server = srv.StatusServer(("127.0.0.1", 0), config, gone, 0)
    err_out = io.StringIO()
    try:
        with contextlib.redirect_stderr(err_out):
            first = server.heartbeat_beat(force=True)
            second = server.heartbeat_beat(force=True)
        check(first is False and second is False and server.heartbeat_counter == 0,
              "a failed write returns False, raises nothing and does not advance the counter")
        text = err_out.getvalue()
        check(text.count("cannot be written") == 1, "the failure is reported once, not on every attempt")
        check("no-such-dir" not in text and "heartbeat" not in text, "the report names no path")
        os.makedirs(os.path.dirname(gone), mode=0o700)
        check(server.heartbeat_beat(force=True) is True and read_counter(gone) == 1,
              "when the directory appears the next write succeeds from 1")
    finally:
        server.server_close()
    if not is_root:
        locked = os.path.join(work, "locked")
        os.makedirs(locked, mode=0o700, exist_ok=True)
        os.chmod(locked, 0o500)
        server = srv.StatusServer(("127.0.0.1", 0), config, os.path.join(locked, "heartbeat"), 0)
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                ok = server.heartbeat_beat(force=True)
            check(ok is False and os.listdir(locked) == [], "a read-only liveness directory: no write, no stray file, no exception")
        finally:
            server.server_close()
            os.chmod(locked, 0o700)
    else:
        skip_block("running as root; the read-only directory check", 1)

    print("-- a stalled accept loop stops the counter (it is written from the loop, not a timer) --")

    class Stallable(srv.StatusServer):
        stall = threading.Event()
        entered = threading.Event()

        def verify_request(self, request, client_address):
            if Stallable.stall.is_set():
                Stallable.entered.set()
                end = time.time() + 20
                while Stallable.stall.is_set() and time.time() < end:
                    time.sleep(0.05)
            return super().verify_request(request, client_address)

    hb3 = os.path.join(work, "hb3", "heartbeat")
    os.makedirs(os.path.dirname(hb3), mode=0o700, exist_ok=True)
    any_config = srv.Config(snap_path, 30, None, srv.Assets(srv.ASSET_DIR))
    stall_server = Stallable(("127.0.0.1", 0), any_config, hb3, 0.05)
    loop = threading.Thread(target=stall_server.serve_forever, kwargs={"poll_interval": 0.05})
    loop.start()
    try:
        first = wait_for(lambda: read_counter(hb3))
        later = wait_for(lambda: (read_counter(hb3) or 0) > (first or 0) + 2 and read_counter(hb3))
        check(bool(first) and bool(later), "the counter advances while the loop runs")
        Stallable.stall.set()
        blocker = socket.create_connection(("127.0.0.1", stall_server.server_address[1]), timeout=5)
        entered = Stallable.entered.wait(5)
        time.sleep(0.3)
        frozen = read_counter(hb3)
        time.sleep(0.8)
        check(entered and read_counter(hb3) == frozen, "the counter stops while the accept loop is blocked")
        Stallable.stall.clear()
        blocker.close()
        resumed = wait_for(lambda: (read_counter(hb3) or 0) > (frozen or 0) and read_counter(hb3))
        check(bool(resumed), "the counter advances again when the loop is released")
    finally:
        Stallable.stall.clear()
        stall_server.shutdown()
        loop.join(10)
        stall_server.server_close()

    print("-- real server process: the liveness counter, and the peer filter with a real connection --")
    if (not is_root and can_bind("127.0.0.2") and can_bind("127.0.0.5")
            and not os.environ.get("HALOW_CHECKS_FORCE_SKIP")):
        run_dir = os.path.join(work, "proc")
        os.makedirs(run_dir, mode=0o700, exist_ok=True)
        hb4 = os.path.join(run_dir, "heartbeat")
        write_json(snap_path, snapshot())
        # Bound to 127.0.0.5, only 127.0.0.2 allowed: the same shape as a service bound to the
        # bridge gateway that serves only the Supervisor's proxy address.
        server = Server(snap_path, allow="127.0.0.2", bind="127.0.0.5",
                        extra=("--heartbeat-file", hb4, "--heartbeat-interval", "0.2"))
        try:
            first = wait_for(lambda: read_counter(hb4))
            check(first is not None, "the real server wrote its first counter value before any connection")
            check(stat.S_IMODE(os.stat(hb4).st_mode) == 0o600, "the real server's counter file is mode 0600")
            check(not os.path.exists(hb4 + ".tmp"), "no temporary file is left by the real server")
            advanced = wait_for(lambda: (read_counter(hb4) or 0) > (first or 0) + 1 and read_counter(hb4))
            check(bool(advanced), "the counter advances with no client ever connected (a liveness proof needs no peer)")
            for path in ("/", "/status.json", "/diagnostics", "/health"):
                status, _, body = request(server.port, "GET", path, source="127.0.0.2", host="127.0.0.5")
                check(status == 200, "the allowed peer is served %s" % path)
            check(request(server.port, "GET", "/health", source="127.0.0.2", host="127.0.0.5")[2].strip() == "ok",
                  "/health still answers ok to the allowed peer")
            check(raw_request_from(server.port, b"GET /health HTTP/1.0\r\n\r\n", None, "127.0.0.5") == b"",
                  "a connection made from the same host with no chosen source (the source is the bind address, as the manager's old probe) is refused")
            probe = socket.create_connection(("127.0.0.5", server.port), timeout=5)
            seen_source = probe.getsockname()[0]
            probe.close()
            print("  note: with no chosen source, loopback picked source %s for a connection to 127.0.0.5 "
                  "(what a bridge address does is not known from this; the manager's own check needs no connection)" % seen_source)
            check(raw_request_from(server.port, b"GET /health HTTP/1.0\r\n\r\n", "127.0.0.5", "127.0.0.5") == b"",
                  "a connection whose source is the server's own bind address (the 172.30.32.1 equivalent) is refused")
            check(raw_request_from(server.port, b"GET /health HTTP/1.0\r\n\r\n", "127.0.0.1", "127.0.0.5") == b"",
                  "a connection from 127.0.0.1 is refused")
            check(raw_request_from(server.port, b"GET /status.json HTTP/1.0\r\n\r\n", "127.0.0.1", "127.0.0.5") == b"",
                  "/status.json is not served to 127.0.0.1")
            check(raw_request_from(server.port, b"GET /health HTTP/1.0\r\n\r\n", "127.0.0.2", "127.0.0.5").startswith(b"HTTP/1.0 200"),
                  "a raw connection from the allowed peer is answered")
            # Stopping the process (a hang) stops the counter; resuming it restarts it.
            os.kill(server.proc.pid, signal.SIGSTOP)
            time.sleep(0.6)
            frozen = read_counter(hb4)
            time.sleep(1.0)
            check(read_counter(hb4) == frozen, "a stopped (hung) server process no longer advances the counter")
            os.kill(server.proc.pid, signal.SIGCONT)
            check(bool(wait_for(lambda: (read_counter(hb4) or 0) > (frozen or 0) and read_counter(hb4))),
                  "the counter advances again when the process runs")
        finally:
            server.stop()
        # Restart: a new process starts the counter again at 1; the stale file is replaced.
        with open(hb4, "w") as handle:
            handle.write("424242\n")
        server = Server(snap_path, allow="127.0.0.2", bind="127.0.0.5",
                        extra=("--heartbeat-file", hb4, "--heartbeat-interval", "5"))
        try:
            check(read_counter(hb4) == 1, "a restarted server replaces a stale counter file with 1 before it announces that it is listening")
        finally:
            server.stop()
        # The status child cannot write its liveness directory: it keeps serving.
        locked = os.path.join(work, "proc-locked")
        os.makedirs(locked, mode=0o700, exist_ok=True)
        os.chmod(locked, 0o500)
        server = Server(snap_path, allow="127.0.0.2", bind="127.0.0.5",
                        extra=("--heartbeat-file", os.path.join(locked, "heartbeat"), "--heartbeat-interval", "0.2"))
        try:
            status, _, _ = request(server.port, "GET", "/health", source="127.0.0.2", host="127.0.0.5")
            time.sleep(0.6)
            check(status == 200 and os.listdir(locked) == [], "a server that cannot write its counter still serves and leaves nothing behind")
        finally:
            server.stop()
            os.chmod(locked, 0o700)
        result = subprocess.run([sys.executable, "-I", SERVER, "--port", "0", "--bind", "127.0.0.5", "--snapshot", snap_path,
                                 "--allow-from", "127.0.0.2", "--heartbeat-interval", "0"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20)
        check(result.returncode == 2, "a heartbeat interval outside 0.1 to 10 seconds is refused")
    else:
        skip_block("the real-process liveness and loopback-alias peer checks (root, or 127.0.0.2/127.0.0.5 cannot be bound here, "
                   "or HALOW_CHECKS_FORCE_SKIP is set); the unit-level peer_allowed/verify_request checks above still ran",
                   REAL_BLOCK_CHECKS)


def end_to_end(snap_path, secret):
    server = Server(snap_path)
    try:
        for path in ("/", "/status.json", "/diagnostics"):
            status, _, body = request(server.port, "GET", path)
            check(status == 200 and secret and secret not in body,
                  "end to end: %s from a state.sh snapshot never contains the passphrase" % path)
        status, _, page = request(server.port, "GET", "/")
        check("Backup channel (automatic selection did not complete)" in page and "Using a backup channel" in page,
              "end to end: fallback source and advisory shown")
        check("02:00:00:00:00:30" in page and "02:00:00:00:01:01" in page and "192.0.2.59" in page
              and "02:00:00:00:01:02" in page and "IP address not available" in page and "192.0.2.80" in page,
              "end to end: the WDS station, both devices and the known addresses reach the page")
        check("<script>alert" not in page and "<img src=x" not in page and "192.0.2.99" not in page
              and "&lt;script&gt;" not in page,
              "end to end: a hostile station and a hostile address were refused by the writer and appear nowhere")
        check(no_removed_wording(page),
              "end to end: the page has none of the removed engineering wording and no bare 'HaLow'")
        status, _, body = request(server.port, "GET", "/status.json")
        data = json.loads(body)
        check(data["stale"] is False and data["overall"] == "operating", "end to end: fresh operating status")
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # a crash is a failure, not a pass
        check(False, "checks crashed: %s: %s" % (type(exc).__name__, exc))
    finally:
        stop_all()
    if not os.environ.get("HALOW_E2E_SNAPSHOT"):
        # Exact, not a floor: a check that silently stops running is a failure. The planned
        # total counts every check of a full run; a skipped block subtracts exactly its own.
        check(COUNT + 1 + SKIPPED_CHECKS == PLANNED_TOTAL,
              "the planned number of checks ran (%d run, %d skipped, %d planned)" % (COUNT + 1, SKIPPED_CHECKS, PLANNED_TOTAL))
        if os.environ.get("HALOW_REQUIRE_REAL_PROC") == "1" and SKIPPED_BLOCKS:
            check(False, "HALOW_REQUIRE_REAL_PROC=1 and %d block(s) were skipped" % SKIPPED_BLOCKS)
    print("status_server_checks: %d/%d passed, %d skipped blocks" % (COUNT - FAILED, COUNT, SKIPPED_BLOCKS))
    sys.exit(1 if FAILED else 0)
