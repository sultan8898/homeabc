#!/usr/bin/env python3
"""
Cloudways account bandwidth inventory (v1 monitor API).

Uses GET /api/v1/server/monitor/summary (and /app/monitor/summary fallback)
to list per-application bandwidth on every server in the account.

Auth (same pattern as sl_enable_cronoptimizer.py on main):
  export CW_ACCESS_TOKEN='cw_...'
  python3 list_bandwidth.py

  # legacy:
  CW_EMAIL='you@example.com' CW_API_KEY='key' python3 list_bandwidth.py

  # one server:
  python3 list_bandwidth.py --server 1447339

Output: table + cloudways_bandwidth_YYYYMMDD_HHMMSS.csv
"""

from __future__ import print_function

import argparse
import csv
import os
import re
import sys
import time
from datetime import datetime, timedelta

import requests

API_V1 = "https://api.cloudways.com/api/v1"
API_V2 = "https://api.cloudways.com/api/v2"
TOKEN_TTL = 3600
RATE_SLEEP = 0.35

_token_cache = {"token": None, "expires_at": None, "api_base": None}


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


def extract_numeric(datapoint):
    if datapoint is None:
        return None
    if isinstance(datapoint, (int, float)):
        if _looks_like_timestamp(datapoint):
            return None
        return float(datapoint)
    if isinstance(datapoint, list):
        for x in datapoint:
            if isinstance(x, (int, float)) and not _looks_like_timestamp(x):
                return float(x)
    return None


def normalize_mb(raw):
    """Monitor values are usually MB; handle byte-scale outliers."""
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
    content = body.get("content")
    if isinstance(content, list):
        return content
    mon = body.get("monitor")
    if isinstance(mon, dict) and isinstance(mon.get("content"), list):
        return mon["content"]
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


def parse_server_bandwidth(content, apps, summary_type):
    """Map sys_user -> MB from server/monitor/summary content."""
    out = {}
    for item in content or []:
        if not isinstance(item, dict):
            continue
        if summary_type == "disk" and not is_bandwidth_row(item):
            continue
        name = str(
            item.get("name") or item.get("label") or item.get("sys_user") or ""
        ).strip()
        raw = extract_numeric(item.get("datapoint"))
        if raw is None:
            raw = extract_numeric(item.get("value"))
        if raw is None:
            raw = extract_numeric(item.get("usage"))
        if raw is None:
            continue
        mb = normalize_mb(raw)
        su = ""
        for app in apps:
            if name == str(app.get("sys_user", "")).strip():
                su = name
                break
        if not su:
            su = match_app_sys_user(name, apps)
        if not su and len(apps) == 1:
            su = str(apps[0].get("sys_user", "")).strip()
        if not su:
            continue
        out[su] = mb
    return out


def server_monitor_summary(token, server_id, summary_type):
    code, body = api_get_v1(
        token,
        "/server/monitor/summary",
        {"server_id": server_id, "type": summary_type},
    )
    if code != 200:
        return None, body
    return monitor_content_list(body), body


def app_monitor_summary(token, server_id, app_id, summary_type):
    params = {"server_id": server_id, "app_id": app_id, "type": summary_type}
    code, body = api_get_v1(token, "/app/monitor/summary", params)
    if code != 200:
        return None, body
    return monitor_content_list(body), body


def fetch_app_bandwidth(token, server_id, app):
    app_id = str(app.get("id", "")).strip()
    su = str(app.get("sys_user", "")).strip()
    if not app_id:
        return None
    for summary_type in ("bandwidth", "bw"):
        content, _ = app_monitor_summary(token, server_id, app_id, summary_type)
        if not content:
            continue
        mb_map = parse_server_bandwidth(content, [app], summary_type)
        if su in mb_map:
            return mb_map[su]
        if len(mb_map) == 1:
            return next(iter(mb_map.values()))
        total = sum(mb_map.values())
        if total:
            return total
    return None


def collect_server_bandwidth(token, server_id, apps, debug=False):
    """Per sys_user bandwidth (MB) for one server."""
    sizes = {}
    used_type = ""
    for summary_type in ("bandwidth", "bw", "disk"):
        content, raw = server_monitor_summary(token, server_id, summary_type)
        if debug:
            print("  [debug] server {} type={} code sample: {}".format(
                server_id, summary_type, str(raw)[:300],
            ))
        if not content:
            continue
        parsed = parse_server_bandwidth(content, apps, summary_type)
        if parsed:
            sizes.update(parsed)
            used_type = summary_type
            break
        time.sleep(0.12)

    missing = [
        a for a in apps
        if str(a.get("sys_user", "")).strip() not in sizes
    ]
    for app in missing:
        su = str(app.get("sys_user", "")).strip()
        mb = fetch_app_bandwidth(token, server_id, app)
        if mb is not None:
            sizes[su] = mb
        time.sleep(RATE_SLEEP)

    return sizes, used_type or "app_fallback"


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
    p = argparse.ArgumentParser(description="Account-wide app bandwidth (monitor summary API).")
    p.add_argument("--access-token", help="cw_ access token (or CW_ACCESS_TOKEN)")
    p.add_argument("--email", help="Cloudways email (legacy API key)")
    p.add_argument("--api-key", help="Legacy API key (or CW_API_KEY)")
    p.add_argument("--server", metavar="ID", help="Limit to one server id")
    p.add_argument("--include-staging", action="store_true", help="Include staging apps")
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

    rows = []
    print("[2] Fetching bandwidth per server (v1 /server/monitor/summary) ...")
    for srv in servers:
        sid = str(srv.get("id", ""))
        label = str(srv.get("label", ""))
        ip = str(srv.get("public_ip", "") or "")
        loc = server_location(srv)
        apps = srv.get("apps") or []
        if not args.include_staging:
            apps = [a for a in apps if str(a.get("is_staging", "0")) != "1"]

        print("    {} ({}) — {} app(s) ...".format(sid, ip or "no-ip", len(apps)), flush=True)
        bw_map, src_type = collect_server_bandwidth(token, sid, apps, debug=args.debug)

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
                "monitor_source": src_type,
            })
        time.sleep(RATE_SLEEP)

    print("\n    {} app row(s).\n".format(len(rows)))
    if not rows:
        sys.exit(0)

    headers = [
        "server_id", "server_label", "server_ip", "server_location",
        "app_id", "app_label", "app_type", "app_url", "sys_user",
        "bandwidth", "bandwidth_mb", "monitor_source",
    ]
    widths = {h: max(len(h), max(len(str(r[h])) for r in rows)) for h in headers}
    line = "  ".join(h.ljust(widths[h]) for h in headers)
    print(line)
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
