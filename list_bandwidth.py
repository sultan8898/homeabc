#!/usr/bin/env python3
"""
Cloudways account bandwidth inventory (v1 monitor API + on-server apm fallback).

Cloudways naming quirk: per-app *bandwidth* often comes from
GET /api/v1/server/monitor/summary?type=disk (rows are type=bw / sys_user).

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
    if raw is None:
        return None
    v = float(raw)
    if v > 5e8:
        return v / (1024.0 * 1024.0)
    if v > 5e5:
        return v / 1024.0
    return v


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


def value_from_item(item):
    for key in ("datapoint", "value", "usage", "size"):
        raw = extract_numeric(item.get(key))
        if raw is not None:
            return normalize_mb(raw)
    return None


def parse_summary_content(content, apps, summary_type):
    """
    Map sys_user -> MB from monitor summary content.

    type=disk on server summary = per-app bandwidth (Cloudways UI naming).
    """
    out = {}
    for item in content or []:
        if not isinstance(item, dict):
            continue
        name = str(
            item.get("name") or item.get("label") or item.get("sys_user") or ""
        ).strip()
        su = match_app_sys_user(name, apps)
        if summary_type == "disk":
            if not su and not is_bandwidth_row(item):
                continue
        mb = value_from_item(item)
        if mb is None:
            continue
        if not su:
            su = match_app_sys_user(name, apps)
        if not su and len(apps) == 1:
            su = str(apps[0].get("sys_user", "")).strip()
        if not su:
            continue
        out[su] = mb
    return out


def parse_body_scalar_mb(body):
    if not isinstance(body, dict):
        return None
    for key in ("bandwidth", "bw", "transfer", "usage", "total", "value"):
        n = extract_numeric(body.get(key))
        if n is not None:
            return normalize_mb(n)
    content = monitor_content_list(body)
    if content:
        mb = value_from_item(content[0]) if content else None
        if mb is not None:
            return mb
        total = 0.0
        found = False
        for item in content:
            v = value_from_item(item)
            if v is not None:
                total += v
                found = True
        if found:
            return total
    return None


def parse_monitor_graph_mb(body):
    if not isinstance(body, dict):
        return None
    nums = []
    for key in ("contents", "content", "data", "graph"):
        block = body.get(key)
        if not isinstance(block, list):
            continue
        for row in block:
            if isinstance(row, list):
                for cell in row[1:]:
                    n = extract_numeric(cell)
                    if n is not None:
                        nums.append(normalize_mb(n))
            elif isinstance(row, dict):
                n = value_from_item(row)
                if n is not None:
                    nums.append(n)
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
    code, body = api_get_v1(token, "/app/monitor/detail", params)
    if code != 200:
        return None
    mb = parse_monitor_graph_mb(body)
    if mb is None:
        mb = parse_body_scalar_mb(body)
    return mb


def fetch_app_bandwidth_api(token, server_id, app, debug=False):
    app_id = str(app.get("id", "")).strip()
    su = str(app.get("sys_user", "")).strip()
    if not app_id:
        return None, "no_app_id"

    for summary_type in ("bandwidth", "bw", "disk"):
        code, content, body = app_monitor_summary(
            token, server_id, app_id, summary_type,
        )
        if debug:
            print("    [debug] app {} summary type={} http={} sample={}".format(
                app_id, summary_type, code, json.dumps(body)[:200],
            ))
        if code != 200:
            continue
        parsed = parse_summary_content(content, [app], summary_type)
        if su in parsed:
            return parsed[su], "app_summary:{}".format(summary_type)
        if len(parsed) == 1:
            return next(iter(parsed.values())), "app_summary:{}".format(summary_type)
        scalar = parse_body_scalar_mb(body)
        if scalar is not None:
            return scalar, "app_summary_body:{}".format(summary_type)
        time.sleep(0.1)

    code, content, body = app_monitor_summary(token, server_id, app_id, None)
    if code == 200:
        parsed = parse_summary_content(content, [app], "bandwidth")
        if su in parsed:
            return parsed[su], "app_summary:no_type"
        scalar = parse_body_scalar_mb(body)
        if scalar is not None:
            return scalar, "app_summary:no_type"

    for target in ("bw", "bandwidth", "traffic"):
        mb = app_monitor_detail(token, server_id, app_id, target)
        if mb is not None:
            return mb, "app_detail:{}".format(target)
        time.sleep(0.1)

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
    sizes = {}
    sources = {}
    last_http = ""

    for summary_type in ("disk", "bandwidth", "bw"):
        code, content, body = server_monitor_summary(token, server_id, summary_type)
        last_http = str(code)
        if debug:
            print("  [debug] server {} summary type={} http={} rows={} sample={}".format(
                server_id, summary_type, code, len(content or []),
                json.dumps(body)[:350],
            ))
        if code != 200:
            continue
        parsed = parse_summary_content(content, apps, summary_type)
        if parsed:
            for su, mb in parsed.items():
                sizes[su] = mb
                sources[su] = "server_summary:{}".format(summary_type)
            break
        time.sleep(0.12)

    for app in apps:
        su = str(app.get("sys_user", "")).strip()
        if not su or su in sizes:
            continue
        mb, src = fetch_app_bandwidth_api(token, server_id, app, debug=debug)
        if mb is not None:
            sizes[su] = mb
            sources[su] = src
        time.sleep(RATE_SLEEP)

    if local_fallback and on_cloudways_server():
        local_sid = detect_local_server_id()
        if not local_sid or str(local_sid) == str(server_id):
            local = collect_local_apm_bandwidth(apps, days)
            for su, mb in local.items():
                if su not in sizes:
                    sizes[su] = mb
                    sources[su] = "apm_traffic_local"
            if local and debug:
                print("  [debug] apm local filled {} app(s)".format(len(local)))

    return sizes, sources, last_http


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
        bw_map, src_map, http_code = collect_server_bandwidth(
            token, sid, apps, args.days, local_fallback, debug=args.debug,
        )

        for app in apps:
            su = str(app.get("sys_user", "")).strip()
            mb = bw_map.get(su)
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
                "bandwidth_mb": "" if mb is None else "{:.2f}".format(mb),
                "bandwidth": format_bandwidth_mb(mb),
                "monitor_source": src_map.get(su, "n/a"),
                "api_http": http_code if mb is None else "",
            })
        time.sleep(RATE_SLEEP)

    missing = sum(1 for r in rows if r["bandwidth"] == "n/a")
    print("\n    {} app row(s), {} without bandwidth.".format(len(rows), missing))
    if missing and not args.debug:
        print("    Re-run with --debug to see API HTTP codes / response samples.")
        print("    On this server, apm fallback uses: {} traffic -s SYS_USER -l {}".format(
            APM_BIN, args.days,
        ))

    if not rows:
        sys.exit(0)

    headers = [
        "server_id", "server_label", "server_ip", "server_location",
        "app_id", "app_label", "app_type", "app_url", "sys_user",
        "bandwidth", "bandwidth_mb", "monitor_source", "api_http",
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
