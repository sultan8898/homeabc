#!/usr/bin/env python3
"""
Cloudways account bandwidth inventory (v1 monitor API + on-server apm fallback).

Cloudways naming: app monitor summary type=bandwidth is DISK (KB).
Network transfer: server bandwidth_monthly + /app/monitor/detail (bw) or apm.

Auth (same as sl_enable_cronoptimizer.py on main):
  export CW_ACCESS_TOKEN='cw_...'
  python3 list_bandwidth.py

On a Cloudways server, if the API returns empty (scoped token / monitor ACL),
falls back to: /usr/local/sbin/apm traffic -s <sys_user> -l <days>
"""

from __future__ import print_function

import argparse
import csv
import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta

import requests

API_V1 = "https://api.cloudways.com/api/v1"
API_V2 = "https://api.cloudways.com/api/v2"
TOKEN_TTL = 3600
RATE_SLEEP = 0.35
APM_BIN = "/usr/local/sbin/apm"

_token_cache = {"token": None, "expires_at": None, "api_base": None}

HUMAN_SIZE_RE = re.compile(
    r"^([\d.,]+)\s*([KMGT])?(?:i?B)?$", re.IGNORECASE,
)


def is_access_token(value):
    return str(value).startswith("cw_")


def auth_headers(token):
    return {"Accept": "application/json", "Authorization": "Bearer {}".format(token)}


def fetch_oauth_token(email, api_key, api_base):
    now = datetime.utcnow()
    if (
        _token_cache["token"]
        and _token_cache["expires_at"]
        and _token_cache["api_base"] == api_base
        and now < _token_cache["expires_at"]
    ):
        return _token_cache["token"]
    try:
        resp = requests.post(
            api_base + "/oauth/access_token",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            json={"email": email, "api_key": api_key},
            timeout=30,
        )
        resp.raise_for_status()
        token = resp.json().get("access_token")
        if not token:
            return None
    except requests.RequestException:
        return None
    _token_cache["token"] = token
    _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
    _token_cache["api_base"] = api_base
    return token


def resolve_auth(email, secret):
    if is_access_token(secret):
        print("  [auth] Using cw_ access token (API v2 list + v1 monitor).")
        return secret, API_V2
    if not email:
        print("[ERROR] CW_EMAIL is required with a legacy API key.")
        sys.exit(1)
    for api_base in (API_V2, API_V1):
        token = fetch_oauth_token(email, secret, api_base)
        if token:
            print("  [auth] OAuth token via {}.".format(api_base))
            return token, api_base
    print("[ERROR] Could not obtain OAuth token.")
    sys.exit(1)


def parse_servers_payload(payload):
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("servers", "data"):
        val = payload.get(key)
        if isinstance(val, list):
            return val
    return []


def fetch_servers(token, api_base):
    servers = []
    seen = set()
    for path in ("server", "servers"):
        url = "{}/{}".format(api_base, path)
        try:
            resp = requests.get(url, headers=auth_headers(token), timeout=60)
            if resp.status_code >= 400:
                continue
            for srv in parse_servers_payload(resp.json()):
                sid = str(srv.get("id", ""))
                if sid and sid not in seen:
                    seen.add(sid)
                    servers.append(srv)
        except (requests.RequestException, ValueError):
            continue
    return servers


def on_cloudways_server():
    return os.path.isdir("/home/master/applications")


def detect_local_server_id():
    try:
        for conf in glob.glob("/home/master/applications/*/conf/server.nginx"):
            with open(conf, "r", errors="ignore") as fh:
                text = fh.read()
            m = re.search(r"[a-z]+-(\d+)-\d+\.cloudwaysapps\.com", text)
            if m:
                return m.group(1)
    except OSError:
        pass
    return ""


def server_location(srv):
    provider = str(srv.get("cloud", "") or srv.get("provider", "") or "").strip()
    region = str(srv.get("region", "") or srv.get("datacenter", "") or "").strip()
    if provider and region:
        return "{}/{}".format(provider, region)
    return provider or region or "n/a"


def app_url(app):
    cname = str(app.get("cname", "") or "").strip()
    if cname:
        return cname
    return str(app.get("app_fqdn", "") or app.get("url", "") or "").strip()


def _looks_like_timestamp(val):
    try:
        v = float(val)
    except (TypeError, ValueError):
        return False
    return v > 1e9


def parse_human_to_mb(text):
    if text is None:
        return None
    s = str(text).strip()
    if not s:
        return None
    m = HUMAN_SIZE_RE.match(s.replace(" ", ""))
    if not m:
        return None
    val = float(m.group(1).replace(",", ""))
    unit = (m.group(2) or "M").upper()
    mult = {"K": 1.0 / 1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}
    return val * mult.get(unit, 1.0)


def extract_numeric(datapoint):
    if datapoint is None:
        return None
    if isinstance(datapoint, (int, float)):
        if _looks_like_timestamp(datapoint):
            return None
        return float(datapoint)
    if isinstance(datapoint, str):
        return parse_human_to_mb(datapoint)
    if isinstance(datapoint, list):
        for x in datapoint:
            n = extract_numeric(x)
            if n is not None:
                return n
    if isinstance(datapoint, dict):
        for k in ("value", "usage", "size", "y", "amount"):
            n = extract_numeric(datapoint.get(k))
            if n is not None:
                return n
    return None


def normalize_mb(raw):
    """Treat monitor scalars as MB unless clearly bytes."""
    if raw is None:
        return None
    v = float(raw)
    if v > 5e8:
        return v / (1024.0 * 1024.0)
    return v


def kb_to_mb(kb):
    if kb is None:
        return None
    return float(kb) / 1024.0


def format_bandwidth_mb(mb):
    if mb is None:
        return "n/a"
    if mb >= 1024.0:
        return "{:.2f} GB".format(mb / 1024.0)
    if mb >= 100:
        return "{:.0f} MB".format(mb)
    return "{:.1f} MB".format(mb)


def api_get_v1(token, path, params):
    try:
        resp = requests.get(
            API_V1 + path,
            headers=auth_headers(token),
            params=params,
            timeout=60,
        )
        body = resp.json() if resp.content else {}
        return resp.status_code, body
    except (requests.RequestException, ValueError) as e:
        return 0, {"error": str(e)}


def monitor_content_list(body):
    if not isinstance(body, dict):
        return []
    for key in ("content", "contents"):
        val = body.get(key)
        if isinstance(val, list):
            return val
    mon = body.get("monitor")
    if isinstance(mon, dict):
        for key in ("content", "contents"):
            val = mon.get(key)
            if isinstance(val, list):
                return val
    return []


def monitor_content_dict(body):
    if not isinstance(body, dict):
        return {}
    for key in ("content", "contents"):
        val = body.get(key)
        if isinstance(val, dict):
            return val
    return {}


def is_disk_usage_dict(d):
    if not isinstance(d, dict):
        return False
    return any(k in d for k in ("app_home", "app_mysql", "app_home_size"))


def match_app_sys_user(name, apps):
    if not name:
        return ""
    name = str(name).strip()
    nl = name.lower()
    for app in apps:
        su = str(app.get("sys_user", "")).strip()
        label = str(app.get("label", "")).strip()
        if name == su or name == label:
            return su
        if nl == su.lower() or nl == label.lower():
            return su
    return ""


def is_bandwidth_row(item):
    if not isinstance(item, dict):
        return False
    t = str(item.get("type", "")).lower()
    name = str(item.get("name", "")).lower()
    if t in ("bw", "bandwidth"):
        return True
    if "bandwidth" in name or name == "bw":
        return True
    return False


def value_from_item(item, allow_size=False):
    for key in ("datapoint", "value", "usage"):
        raw = extract_numeric(item.get(key))
        if raw is not None:
            return normalize_mb(raw)
    if allow_size:
        raw = extract_numeric(item.get("size"))
        if raw is not None:
            return kb_to_mb(raw)
    return None


def parse_server_monthly_bandwidth_mb(content):
    """Server-wide monthly transfer from bandwidth_monthly row (MB)."""
    for item in content or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", "")).lower()
        if not is_bandwidth_row(item) and "bandwidth" not in name:
            continue
        mb = value_from_item(item)
        if mb is not None:
            return mb
    return None


def parse_per_app_bandwidth_rows(content, apps):
    """Rare: server summary lists one row per app sys_user with type=bw."""
    out = {}
    for item in content or []:
        if not isinstance(item, dict):
            continue
        if not is_bandwidth_row(item):
            continue
        name = str(item.get("name") or item.get("label") or "").strip()
        if name.lower() in ("bandwidth_monthly", "bandwidth", "bw"):
            continue
        su = match_app_sys_user(name, apps)
        if not su:
            continue
        mb = value_from_item(item)
        if mb is not None:
            out[su] = mb
    return out


def app_disk_mb_from_summary(body):
    """App monitor summary type=bandwidth returns disk totals in KB."""
    block = monitor_content_dict(body)
    if not is_disk_usage_dict(block):
        return None
    total = block.get("total")
    if total is not None:
        return kb_to_mb(float(total))
    home = block.get("app_home") or block.get("app_home_size") or 0
    mysql = block.get("app_mysql") or 0
    try:
        return kb_to_mb(float(home) + float(mysql))
    except (TypeError, ValueError):
        return None


def parse_monitor_graph_mb(body):
    """Best-effort: latest point from monitor detail graph (values usually MB)."""
    if not isinstance(body, dict):
        return None
    nums = []

    def walk(node):
        if isinstance(node, list):
            if len(node) >= 2 and isinstance(node[0], (int, float)) and node[0] > 1e9:
                n = extract_numeric(node[1])
                if n is not None:
                    nums.append(normalize_mb(n))
                return
            for el in node:
                walk(el)
        elif isinstance(node, dict):
            for k, v in node.items():
                if k in ("datapoint", "value", "y", "usage", "total"):
                    n = extract_numeric(v)
                    if n is not None:
                        nums.append(normalize_mb(n))
                else:
                    walk(v)

    walk(body.get("contents"))
    walk(body.get("content"))
    walk(body.get("data"))
    if nums:
        return nums[-1]
    return None


def server_monitor_summary(token, server_id, summary_type):
    params = {"server_id": server_id, "type": summary_type}
    code, body = api_get_v1(token, "/server/monitor/summary", params)
    return code, monitor_content_list(body), body


def app_monitor_summary(token, server_id, app_id, summary_type=None):
    params = {"server_id": server_id, "app_id": app_id}
    if summary_type:
        params["type"] = summary_type
    code, body = api_get_v1(token, "/app/monitor/summary", params)
    return code, monitor_content_list(body), body


def app_monitor_detail(token, server_id, app_id, target, duration="1 Month"):
    params = {
        "server_id": server_id,
        "app_id": app_id,
        "target": target,
        "duration": duration,
        "timezone": "UTC",
    }
    return api_get_v1(token, "/app/monitor/detail", params)


def fetch_app_disk_mb(token, server_id, app, debug=False):
    app_id = str(app.get("id", "")).strip()
    if not app_id:
        return None
    for summary_type in ("bandwidth", "bw"):
        code, _, body = app_monitor_summary(token, server_id, app_id, summary_type)
        if code != 200:
            continue
        mb = app_disk_mb_from_summary(body)
        if mb is not None:
            return mb
    return None


def fetch_app_network_mb(token, server_id, app, debug=False):
    """Per-app network transfer (MB), not disk folder sizes."""
    app_id = str(app.get("id", "")).strip()
    if not app_id:
        return None, "no_app_id"

    for duration in ("1 Month", "7 Days", "1 Day"):
        for target in ("bw", "bandwidth", "traffic", "data", "web"):
            code, body = app_monitor_detail(
                token, server_id, app_id, target, duration,
            )
            if debug and code != 200:
                print("    [debug] app {} detail target={} duration={} http={}".format(
                    app_id, target, duration, code,
                ))
            if code != 200:
                continue
            mb = parse_monitor_graph_mb(body)
            if mb is not None:
                return mb, "app_detail:{}:{}".format(target, duration)
            time.sleep(0.08)

    return None, "api_empty"


def local_apm_traffic_mb(sys_user, days):
    if not os.path.isfile(APM_BIN) or not sys_user:
        return None
    try:
        proc = subprocess.run(
            [APM_BIN, "traffic", "-s", sys_user, "-l", str(days)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            universal_newlines=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = proc.stdout or ""
    best = None
    for line in text.splitlines():
        ll = line.lower()
        if "total" in ll or "transfer" in ll or "bandwidth" in ll or "incoming" in ll:
            for m in re.finditer(r"([\d.,]+)\s*([KMGT])?i?B", line, re.I):
                mb = parse_human_to_mb(m.group(0))
                if mb is not None:
                    best = mb if best is None else max(best, mb)
    if best is not None:
        return best
    for m in re.finditer(r"([\d.,]+)\s*([KMGT])?i?B", text, re.I):
        mb = parse_human_to_mb(m.group(0))
        if mb is not None:
            best = mb if best is None else max(best, mb)
    return best


def collect_local_apm_bandwidth(apps, days):
    out = {}
    for app in apps:
        su = str(app.get("sys_user", "")).strip()
        if not su:
            continue
        mb = local_apm_traffic_mb(su, days)
        if mb is not None:
            out[su] = mb
    return out


def collect_server_bandwidth(token, server_id, apps, days, local_fallback, debug=False):
    network = {}
    sources = {}
    disk_mb = {}
    server_monthly_mb = None
    last_http = ""

    for summary_type in ("bandwidth", "bw", "disk"):
        code, content, body = server_monitor_summary(token, server_id, summary_type)
        last_http = str(code)
        if debug:
            print("  [debug] server {} summary type={} http={} rows={} sample={}".format(
                server_id, summary_type, code, len(content or []),
                json.dumps(body)[:350],
            ))
        if code != 200:
            continue
        if server_monthly_mb is None:
            server_monthly_mb = parse_server_monthly_bandwidth_mb(content)
        per_app = parse_per_app_bandwidth_rows(content, apps)
        if per_app:
            for su, mb in per_app.items():
                network[su] = mb
                sources[su] = "server_summary_per_app:{}".format(summary_type)
        time.sleep(0.12)

    for app in apps:
        su = str(app.get("sys_user", "")).strip()
        if not su:
            continue
        dmb = fetch_app_disk_mb(token, server_id, app, debug=debug)
        if dmb is not None:
            disk_mb[su] = dmb
        if su in network:
            continue
        mb, src = fetch_app_network_mb(token, server_id, app, debug=debug)
        if mb is not None:
            network[su] = mb
            sources[su] = src
        time.sleep(RATE_SLEEP)

    if local_fallback and on_cloudways_server():
        local_sid = detect_local_server_id()
        if not local_sid or str(local_sid) == str(server_id):
            local = collect_local_apm_bandwidth(apps, days)
            for su, mb in local.items():
                if su not in network:
                    network[su] = mb
                    sources[su] = "apm_traffic_local"
            if local and debug:
                print("  [debug] apm local filled {} app(s)".format(len(local)))

    return network, sources, disk_mb, server_monthly_mb, last_http


def load_credentials(args):
    token = (
        (args.access_token or "").strip()
        or os.environ.get("CW_ACCESS_TOKEN", "").strip()
    )
    if token:
        return "", token
    email = (args.email or os.environ.get("CW_EMAIL", "")).strip()
    secret = (args.api_key or os.environ.get("CW_API_KEY", "")).strip()
    if secret:
        return email, secret
    print("[ERROR] Set CW_ACCESS_TOKEN or CW_EMAIL + CW_API_KEY.")
    sys.exit(1)


def parse_args(argv):
    p = argparse.ArgumentParser(description="Account-wide app bandwidth (monitor API + apm fallback).")
    p.add_argument("--access-token", help="cw_ access token (or CW_ACCESS_TOKEN)")
    p.add_argument("--email", help="Cloudways email (legacy API key)")
    p.add_argument("--api-key", help="Legacy API key (or CW_API_KEY)")
    p.add_argument("--server", metavar="ID", help="Limit to one server id")
    p.add_argument("--include-staging", action="store_true", help="Include staging apps")
    p.add_argument("--days", type=int, default=30, metavar="N",
                   help="APM traffic lookback days when API empty (default: 30)")
    p.add_argument("--no-local-apm", action="store_true",
                   help="Do not use apm traffic on this server when API is empty")
    p.add_argument("--debug", action="store_true", help="Print API debug snippets")
    return p.parse_args(argv)


def main():
    args = parse_args(sys.argv[1:])
    email, secret = load_credentials(args)
    token, api_base = resolve_auth(email, secret)

    print("\n[1] Fetching servers ...")
    servers = fetch_servers(token, api_base)
    if args.server:
        servers = [s for s in servers if str(s.get("id")) == str(args.server)]
    if not servers:
        print("[ERROR] No servers matched.")
        sys.exit(1)

    local_fallback = not args.no_local_apm
    if local_fallback and on_cloudways_server():
        print("  [note] On-server apm traffic fallback enabled (--days {}).".format(args.days))

    rows = []
    print("[2] Fetching bandwidth (try server summary type=disk first) ...")
    for srv in servers:
        sid = str(srv.get("id", ""))
        label = str(srv.get("label", ""))
        ip = str(srv.get("public_ip", "") or "")
        loc = server_location(srv)
        apps = srv.get("apps") or []
        if not args.include_staging:
            apps = [a for a in apps if str(a.get("is_staging", "0")) != "1"]

        print("    {} ({}) — {} app(s) ...".format(sid, ip or "no-ip", len(apps)), flush=True)
        bw_map, src_map, disk_map, server_monthly, http_code = collect_server_bandwidth(
            token, sid, apps, args.days, local_fallback, debug=args.debug,
        )

        for app in apps:
            su = str(app.get("sys_user", "")).strip()
            mb = bw_map.get(su)
            dmb = disk_map.get(su)
            rows.append({
                "server_id": sid,
                "server_label": label,
                "server_ip": ip,
                "server_location": loc,
                "app_id": str(app.get("id", "")),
                "app_label": str(app.get("label", "")),
                "app_type": str(app.get("application", "")),
                "app_url": app_url(app),
                "sys_user": su,
                "server_bandwidth_monthly_mb": "" if server_monthly is None else "{:.2f}".format(server_monthly),
                "server_bandwidth_monthly": format_bandwidth_mb(server_monthly),
                "app_bandwidth_mb": "" if mb is None else "{:.2f}".format(mb),
                "app_bandwidth": format_bandwidth_mb(mb),
                "app_disk_mb": "" if dmb is None else "{:.2f}".format(dmb),
                "app_disk": format_bandwidth_mb(dmb),
                "monitor_source": src_map.get(su, "n/a"),
                "api_http": http_code if mb is None else "",
            })
        time.sleep(RATE_SLEEP)

    missing = sum(1 for r in rows if r["app_bandwidth"] == "n/a")
    print("\n    {} app row(s), {} without per-app network bandwidth.".format(len(rows), missing))
    if rows and rows[0].get("server_bandwidth_monthly_mb"):
        print("    Server monthly total (all apps): {} MB".format(
            rows[0]["server_bandwidth_monthly_mb"],
        ))
    if missing and not args.debug:
        print("    Re-run with --debug. Per-app network may need app_detail or apm traffic.")
        print("    app_disk_* columns come from app monitor summary (disk, not transfer).")

    if not rows:
        sys.exit(0)

    headers = [
        "server_id", "server_label", "server_ip", "server_location",
        "app_id", "app_label", "app_type", "app_url", "sys_user",
        "server_bandwidth_monthly", "server_bandwidth_monthly_mb",
        "app_bandwidth", "app_bandwidth_mb",
        "app_disk", "app_disk_mb",
        "monitor_source", "api_http",
    ]
    widths = {h: max(len(h), max(len(str(r[h])) for r in rows)) for h in headers}
    line = "  ".join(h.ljust(widths[h]) for h in headers)
    print("\n" + line)
    print("-" * len(line))
    for r in rows:
        print("  ".join(str(r[h]).ljust(widths[h]) for h in headers))

    stamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    csvpath = os.path.join(os.getcwd(), "cloudways_bandwidth_{}.csv".format(stamp))
    with open(csvpath, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        writer.writerows(rows)
    print("\nCSV written to: {}".format(os.path.abspath(csvpath)))


if __name__ == "__main__":
    main()
