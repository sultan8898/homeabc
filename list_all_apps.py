#!/usr/bin/env python3
"""
Cloudways Account App Inventory (v2 API + v1 monitor for sizes)

Read-only account-wide app list with per-app file + DB sizes.

Size sources (pick at prompt):
  api   -- v1 monitor API (all servers, no SSH/cng; ~24h lag vs live du)
  local -- du -sch on current server only
  cng   -- du on all servers via cw-proxy cng
  ssh   -- du via ssh root@public_ip
  skip

Per-app disk breakdown (folder-level, like APM disk tab):
  python3 list_all_apps.py --breakdown --apps ffatvrgvnx,bxhqezvyyp --mode api
  python3 list_all_apps.py --breakdown --server 12345 --mode local

Run on a Cloudways server (no download, no API key — OAuth is blocked from server IP):
  curl -fsSL 'https://raw.githubusercontent.com/sultan8898/homeabc/main/list_all_apps.py' \\
    | python3 - --breakdown --apps nntrtuvbrv

  # all apps on this server:
  curl -fsSL '...' | python3 - --breakdown --mode local

Run from cw-proxy / laptop with API (account-wide or other servers):
  curl -fsSL '...' | CW_EMAIL='you@example.com' CW_API_KEY='your-key' python3 - \\
    --mode api --breakdown --apps ffatvrgvnx

Python 3.5+ (cw-proxy).
"""

import argparse
import base64
import csv
import glob
import json
import os
import re
import sys
import time
import getpass
import shutil
import subprocess
import shlex
from datetime import datetime, timedelta

import requests

if sys.version_info < (3, 5):
    sys.exit("Python 3.5+ required.")

API_V2 = "https://api.cloudways.com/api/v2"
API_V1 = "https://api.cloudways.com/api/v1"
TOKEN_TTL = 3600
SCRIPT_BUILD = "app-disk-breakdown-v5"
SCRIPT_RAW_URL = (
    "https://raw.githubusercontent.com/sultan8898/homeabc/"
    "cursor/app-disk-breakdown-c2aa/list_all_apps.py"
)
SCRIPT_CURL_LOCAL = (
    "curl -fsSL '{url}' | python3 - --breakdown --mode local".format(url=SCRIPT_RAW_URL)
)
SCRIPT_CURL_API = (
    "curl -fsSL '{url}' | CW_EMAIL='you@example.com' CW_API_KEY='your-key' "
    "python3 - --mode api --breakdown".format(url=SCRIPT_RAW_URL)
)

_token_cache = {"token": None, "expires_at": None}


def fetch_token(email, api_key):
    now = datetime.utcnow()
    if (
        _token_cache["token"]
        and _token_cache["expires_at"]
        and now < _token_cache["expires_at"]
    ):
        return _token_cache["token"]

    print("  [token] Requesting new access token ...")
    last_err = None
    for api_base in (API_V2, API_V1):
        label = "v2" if api_base == API_V2 else "v1"
        try:
            resp = requests.post(
                api_base + "/oauth/access_token",
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
                json={"email": email, "api_key": api_key},
                timeout=30,
            )
            resp.raise_for_status()
            token = resp.json().get("access_token")
            if not token:
                last_err = "No access_token in {} response: {}".format(
                    label, resp.text[:300],
                )
                continue
            _token_cache["token"] = token
            _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
            print("  [token] Token obtained ({}).".format(label))
            return token
        except requests.RequestException as e:
            last_err = "{} OAuth failed: {}".format(label, e)
            continue

    print("[ERROR] OAuth request failed.")
    if last_err:
        print("  {}".format(last_err))
    print("  On a Cloudways server, use live du (no API key):")
    print("  {}".format(SCRIPT_CURL_LOCAL))
    sys.exit(1)


def auth_headers(token):
    return {"Accept": "application/json", "Authorization": "Bearer {}".format(token)}


def fetch_all_servers(token):
    last_err = None
    for path in (API_V2 + "/server", API_V1 + "/server"):
        try:
            resp = requests.get(path, headers=auth_headers(token), timeout=60)
            resp.raise_for_status()
            body = resp.json()
            servers = body.get("servers")
            if servers is None and isinstance(body, list):
                servers = body
            return servers or []
        except requests.RequestException as e:
            last_err = e
            continue
    print("[ERROR] Failed to fetch server list: {}".format(last_err))
    sys.exit(1)


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


def discover_local_apps():
    """List every app on this Cloudways server from /home/master/applications."""
    apps = []
    seen = set()
    for conf in sorted(glob.glob("/home/master/applications/*/conf/server.nginx")):
        parts = conf.split("/")
        try:
            idx = parts.index("applications")
            sys_user = parts[idx + 1]
        except (ValueError, IndexError):
            continue
        if not sys_user or sys_user in seen or sys_user == "sample":
            continue
        seen.add(sys_user)
        apps.append({
            "sys_user": sys_user,
            "label": sys_user,
            "id": "",
            "mysql_db_name": sys_user,
        })
    return apps


def filter_local_apps(apps, app_filters):
    if not app_filters:
        return apps
    lowered = [a.lower() for a in app_filters]
    out = []
    for app in apps:
        su = str(app.get("sys_user", "")).strip().lower()
        label = str(app.get("label", "")).strip().lower()
        if su in lowered or label in lowered or any(f in su for f in lowered):
            out.append(app)
    return out


def on_cloudways_server():
    return bool(detect_local_server_id()) and os.path.isdir("/home/master/applications")


def can_run_without_api(args, on_cw):
    """On a Cloudways server, breakdown uses live du (API OAuth is often 403)."""
    if not on_cw:
        return False
    if args.breakdown or args.totals_only:
        return True
    if args.mode == "local":
        return True
    return False


def run_local_server_breakdown(apps, server_id, top_n, totals_only, as_json,
                               debug=False, depth=2):
    """Breakdown for all apps on this server using apm + du."""
    print("  Collecting sizes (bulk du + apm) ...")
    sizes = collect_sizes_local(apps, debug=debug)
    report = {"server_id": server_id or "local", "apps": []}
    total_apps = len(apps)
    for idx, app in enumerate(apps, 1):
        su = str(app.get("sys_user", "")).strip()
        entry = sizes.get(su, {})
        app_rec = {
            "server_id": server_id or "local",
            "server_ip": "localhost",
            "app_id": "",
            "app_label": str(app.get("label", su)),
            "sys_user": su,
            "files_size": entry.get("files_size", "n/a"),
            "db_size": entry.get("db_size", "n/a"),
            "folders": [],
        }
        if not totals_only:
            if total_apps > 3:
                print("    [{}/{}] {} ...".format(idx, total_apps, su), flush=True)
            folders = collect_app_breakdown_local(
                su, top_n=top_n, depth=depth, debug=debug,
            )
            app_rec["folders"] = [
                {"path": f["path"], "size_mb": f["size_mb"],
                 "size": format_gib(f["size_mb"])}
                for f in folders
            ]
        report["apps"].append(app_rec)

    if as_json:
        print(json.dumps(report, indent=2))
        return report

    print("\n=== App disk breakdown (this server, live du) ===\n")
    if len(report["apps"]) > 1:
        print("App totals:")
        render_app_totals_bar_chart(report["apps"])
        print()
    if totals_only:
        return report

    for rec in report["apps"]:
        header = "{}  files={}  db={}".format(
            rec["sys_user"], rec["files_size"], rec["db_size"],
        )
        print(header)
        render_bar_chart(
            [{"path": f["path"], "size_mb": f["size_mb"]} for f in rec["folders"]],
            limit=top_n,
        )
        print()
    return report


def _looks_like_timestamp(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return False
    return 1500000000 <= f <= 2100000000


def format_mb_display(mb):
    if mb is None:
        return "n/a"
    try:
        mb = float(mb)
    except (TypeError, ValueError):
        return "n/a"
    if mb >= 1024:
        return "{:.1f}G".format(mb / 1024.0)
    if abs(mb - int(mb)) < 0.05:
        return "{}M".format(int(mb))
    return "{:.1f}M".format(mb)


def extract_size_mb(datapoint):
    """Monitor API: datapoint is [size_mb, timestamp] or a bare number."""
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
        fqdn = str(app.get("app_fqdn", "") or "")
        if fqdn and nl in fqdn.lower():
            return su
    return ""


def api_get_v1(token, path, params, timeout=60):
    try:
        resp = requests.get(
            API_V1 + path,
            headers=auth_headers(token),
            params=params,
            timeout=timeout,
        )
        return resp.status_code, resp.json() if resp.content else {}
    except (requests.RequestException, ValueError) as e:
        return 0, {"error": str(e)}


def monitor_content_list(body):
    if not isinstance(body, dict):
        return []
    content = body.get("content")
    if isinstance(content, list):
        return content
    if isinstance(body.get("monitor"), dict):
        c = body["monitor"].get("content")
        if isinstance(c, list):
            return c
    return []


def server_monitor_summary(token, server_id, summary_type):
    code, body = api_get_v1(
        token,
        "/server/monitor/summary",
        {"server_id": server_id, "type": summary_type},
    )
    if code != 200:
        return None, body
    return monitor_content_list(body), body


def sum_content_mb(content):
    """Sum folder lines from app monitor; prefer explicit total row."""
    if not content:
        return None
    total = 0.0
    found = False
    for item in content:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", "")).lower()
        mb = extract_size_mb(item.get("datapoint"))
        if mb is None:
            mb = extract_size_mb(item.get("value"))
        if mb is None:
            mb = extract_size_mb(item.get("usage"))
        if mb is None:
            mb = extract_size_mb(item.get("size"))
        if mb is None:
            continue
        if name == "total" or name.endswith(" total") or "total" == name:
            return mb
        total += mb
        found = True
    return total if found else None


def parse_files_mb_from_body(body):
    """Parse app file / webroot size (MB) from assorted API response shapes."""
    if body is None:
        return None
    if isinstance(body, (int, float)):
        if not _looks_like_timestamp(body):
            return float(body)
        return None
    if isinstance(body, list):
        return sum_content_mb(body)
    if not isinstance(body, dict):
        return None

    # Top-level numeric keys (webroot size, etc.)
    file_keys = (
        "webroot", "webfiles", "files", "app_disk", "application",
        "disk_usage", "file_usage", "usage", "size", "value",
    )
    total = 0.0
    found = False
    for k in file_keys:
        v = body.get(k)
        if isinstance(v, (int, float)) and not _looks_like_timestamp(v):
            total += float(v)
            found = True
    if found:
        return total

    content = monitor_content_list(body)
    if content:
        mb = sum_content_mb(content)
        if mb is not None:
            return mb

    for v in body.values():
        if isinstance(v, (dict, list)):
            mb = parse_files_mb_from_body(v)
            if mb is not None:
                return mb
    return None


def app_monitor_summary(token, server_id, app_id, summary_type):
    params = {"server_id": server_id, "app_id": app_id}
    if summary_type:
        params["type"] = summary_type
    code, body = api_get_v1(token, "/app/monitor/summary", params)
    if code != 200:
        return None, body
    return monitor_content_list(body), body


def is_bandwidth_only_content(content):
    """server/monitor/summary type=disk often returns bw, not app files."""
    if not content:
        return False
    for item in content:
        if not isinstance(item, dict):
            continue
        t = str(item.get("type", "")).lower()
        name = str(item.get("name", "")).lower()
        if t == "bw" or "bandwidth" in name:
            return True
    return False


def apply_content_to_sizes(sizes, content, apps, field):
    for item in content or []:
        if not isinstance(item, dict):
            continue
        name = str(
            item.get("name") or item.get("label") or item.get("sys_user") or ""
        ).strip()
        mb = extract_size_mb(item.get("datapoint"))
        if mb is None:
            mb = extract_size_mb(item.get("size"))
        if mb is None:
            mb = extract_size_mb(item.get("value"))
        if mb is None:
            continue
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
        sizes.setdefault(su, {})
        sizes[su][field] = format_mb_display(mb)


def fetch_app_files_mb(token, server_id, app_id, debug=False):
    """Application web/files disk — not available on server/monitor/summary type=db."""
    disk_paths = (
        "/app/disk_usage",
        "/app/manage/diskUsage",
        "/app/monitor/diskUsage",
        "/server/monitor/diskUsage",
    )
    for path in disk_paths:
        code, body = api_get_v1(
            token, path, {"server_id": server_id, "app_id": app_id},
        )
        if debug and code:
            print("  [debug] {} {} -> {}".format(path, code, str(body)[:300]))
        if code == 200:
            mb = parse_files_mb_from_body(body)
            if mb is not None:
                return mb

    file_types = (
        "apps", "disk_usage", "webroot", "disk", "web", "files", "file",
        "data", "usage", "application", "app",
    )
    for t in file_types:
        content, body = app_monitor_summary(token, server_id, app_id, t)
        mb = sum_content_mb(content) if content else None
        if mb is None:
            mb = parse_files_mb_from_body(body)
        if mb is not None:
            return mb
        time.sleep(0.12)

    # Without type param (some accounts)
    content, body = app_monitor_summary(token, server_id, app_id, None)
    mb = sum_content_mb(content) if content else None
    if mb is None:
        mb = parse_files_mb_from_body(body)
    if mb is not None:
        return mb

    for target in ("disk_usage", "disk", "webroot", "web", "files", "file"):
        code, body = api_get_v1(
            token,
            "/app/monitor/detail",
            {
                "server_id": server_id,
                "app_id": app_id,
                "target": target,
                "duration": "24h",
                "timezone": "UTC",
            },
        )
        if code == 200:
            mb = parse_files_mb_from_body(body)
            if mb is not None:
                return mb
        time.sleep(0.1)
    return None


def pick_app_monitor_size(content, apps):
    """Single value from monitor content (DB tables etc.)."""
    mb = sum_content_mb(content)
    if mb is not None:
        return mb
    return None


def fill_missing_sizes_via_local_du(servers, sizes_by_server, local_sid):
    """
    On a Cloudways server: monitor type=db is app FILES, not MySQL.
    Local du fills missing files_size and/or db_size (/var/lib/mysql/<db_name>).
    """
    if not local_sid:
        return
    if os.environ.get("API_DU_FILL_LOCAL", "1").strip() in ("0", "no", "false"):
        return
    target = next((s for s in servers if str(s.get("id")) == local_sid), None)
    if not target:
        return
    server_sizes = sizes_by_server.get(local_sid)
    if not server_sizes or server_sizes == "SKIPPED":
        return
    apps = target.get("apps", [])
    need_files = need_db = False
    for app in apps:
        su = str(app.get("sys_user", "")).strip()
        ent = server_sizes.get(su) or {}
        if ent.get("files_size") in (None, "", "n/a"):
            need_files = True
        if ent.get("db_size") in (None, "", "n/a"):
            need_db = True
    if not need_files and not need_db:
        return
    print(
        "\n  [api] Filling missing sizes via local du on server {} "
        "(files=app tree, db=/var/lib/mysql/<db_name>) ...".format(local_sid)
    )
    du_sizes = collect_sizes_local(apps)
    for su, du in du_sizes.items():
        if not server_sizes.get(su):
            server_sizes[su] = {}
        if need_files and server_sizes[su].get("files_size") in (None, "", "n/a"):
            server_sizes[su]["files_size"] = du.get("files_size", "n/a")
        if need_db and server_sizes[su].get("db_size") in (None, "", "n/a"):
            server_sizes[su]["db_size"] = du.get("db_size", "n/a")
    print("    local du updated {} app(s)".format(len(du_sizes)))


def collect_sizes_api_for_server(token, server_id, apps):
    sizes = {}
    debug = os.environ.get("MONITOR_DEBUG", "").strip() == "1"

    # Cloudways monitor: type=db = per-app APPLICATION disk (files), names=sys_user.
    # (type=disk on server summary returns bandwidth / type=bw — not files.)
    content, raw = server_monitor_summary(token, server_id, "db")
    if debug:
        print("\n  [debug] server {} type=db (app FILES) sample: {}".format(
            server_id, str(raw)[:400],
        ))
    if content:
        apply_content_to_sizes(sizes, content, apps, "files_size")

    # Real MySQL datadir sizes — try server summary types (often empty).
    for summary_type in ("mysql", "database", "mysqldb", "dbase", "data"):
        content, raw = server_monitor_summary(token, server_id, summary_type)
        if not content or is_bandwidth_only_content(content):
            continue
        if debug:
            print("  [debug] server {} type={} (DB) hits={}".format(
                server_id, summary_type, len(content),
            ))
        apply_content_to_sizes(sizes, content, apps, "db_size")
        if any(
            sizes.get(str(a.get("sys_user", "")).strip(), {}).get("db_size")
            for a in apps
        ):
            break

    db_types = ("db", "mysql", "database")

    for app in apps:
        su = str(app.get("sys_user", "")).strip()
        app_id = str(app.get("id", "")).strip()
        if not su or not app_id:
            continue
        entry = sizes.setdefault(su, {})

        if not entry.get("files_size"):
            mb = fetch_app_files_mb(token, server_id, app_id, debug=debug)
            if mb is not None:
                entry["files_size"] = format_mb_display(mb)

        if not entry.get("db_size"):
            for t in db_types:
                content, _ = app_monitor_summary(token, server_id, app_id, t)
                mb = pick_app_monitor_size(content, apps)
                if mb is not None:
                    entry["db_size"] = format_mb_display(mb)
                    break
                time.sleep(0.12)

        if not entry.get("files_size"):
            entry["files_size"] = "n/a"
        if not entry.get("db_size"):
            entry["db_size"] = "n/a"

    return sizes


def build_bulk_du_script():
    """One-pass du for all app homes + mysql datadirs (Cloudways paths)."""
    return "\n".join([
        "set +e",
        "DU=/usr/bin/du",
        '[ -x "$DU" ] || DU=du',
        '_emit() {',
        '  local kind="$1" name="$2" kb="$3"',
        '  [ -n "$name" ] && [ -n "$kb" ] && printf "%s\\t%s\\t%sK\\n" "$kind" "$name" "$kb"',
        '}',
        '_scan_apps() {',
        '  local base="$1" strip="$2"',
        '  [ -d "$base" ] || return 0',
        '  local d name su kb',
        '  for d in "$base"/*; do',
        '    [ -d "$d" ] || continue',
        '    name=$(basename "$d")',
        '    case "$name" in sample|master|lost+found|.*) continue ;; esac',
        '    su="$name"',
        '    if [ "$strip" = "1" ]; then su="${su%.cloudwaysapps.com}"; fi',
        '    kb=$("$DU" -sk "$d" 2>/dev/null | awk "{print \\$1}")',
        '    _emit F "$su" "$kb"',
        '  done',
        '}',
        '_scan_apps /home/master/applications 0',
        '_scan_apps /home 1',
        'if [ -d /var/lib/mysql ]; then',
        '  for d in /var/lib/mysql/*; do',
        '    [ -d "$d" ] || continue',
        '    name=$(basename "$d")',
        '    kb=$("$DU" -sk "$d" 2>/dev/null | awk "{print \\$1}")',
        '    _emit D "$name" "$kb"',
        '  done',
        'fi',
    ])


def parse_bulk_du_output(stdout):
    sizes = {}
    for line in (stdout or "").splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        kind, name, raw = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if not name or not raw:
            continue
        mb = parse_human_size_to_mb(raw)
        if mb is None:
            continue
        disp = format_mb_display(mb)
        sizes.setdefault(name, {})
        if kind == "F":
            sizes[name]["files_size"] = disp
        elif kind == "D":
            sizes[name]["db_size"] = disp
    for ent in sizes.values():
        ent.setdefault("files_size", "n/a")
        ent.setdefault("db_size", "n/a")
    return sizes


def build_per_app_du_script(apps):
    """Per-app du fallback when bulk scan misses an app."""
    lines = ["set +e", "DU=/usr/bin/du", '[ -x "$DU" ] || DU=du']
    for app in apps:
        sys_user = str(app.get("sys_user", "")).strip()
        if not sys_user:
            continue
        db_name = str(app.get("mysql_db_name", "") or sys_user).strip()
        bases = [
            "/home/master/applications/{}".format(sys_user),
            "/home/{}.cloudwaysapps.com".format(sys_user),
        ]
        db_dir = "/var/lib/mysql/{}".format(db_name)
        su = shlex.quote(sys_user)
        dd = shlex.quote(db_dir)
        ad_list = " ".join(shlex.quote(b) for b in bases)
        lines.append(
            "fu=\"\"; for ad in {ads}; do "
            "[ -d \"$ad\" ] || continue; "
            "fu=$($DU -sh \"$ad\" 2>/dev/null | awk '{{print $1}}'); "
            "[ -n \"$fu\" ] && break; done; "
            "db=$($DU -sh {dd} 2>/dev/null | awk '{{print $1}}'); "
            "printf '%s\\t%s\\t%s\\n' {su} \"$fu\" \"$db\"".format(
                ads=ad_list, dd=dd, su=su,
            )
        )
    return "\n".join(lines)


def parse_du_output(stdout):
    sizes = {}
    for line in stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        sys_user = parts[0].strip()
        sizes[sys_user] = {
            "files_size": parts[1].strip() or "n/a",
            "db_size": parts[2].strip() or "n/a",
        }
    return sizes


def run_subprocess(cmd, input_text=None, timeout=300):
    return subprocess.run(
        cmd,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=timeout,
    )


def run_remote_script(mode, server_ip, script, ssh_user, cng_argv):
    b64 = base64.b64encode(script.encode()).decode()
    remote = "echo {} | base64 -d | bash".format(shlex.quote(b64))
    if mode == "cng":
        cmd = cng_argv + [server_ip, remote]
    else:
        cmd = [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new",
            "{}@{}".format(ssh_user, server_ip),
            remote,
        ]
    try:
        result = run_subprocess(cmd)
    except (subprocess.TimeoutExpired, OSError) as e:
        return "", False, str(e)

    err = (result.stderr or "").strip()
    out = result.stdout or ""
    if result.returncode != 0 and not out.strip():
        return out, False, err or "exit {}".format(result.returncode)
    return out, True, err


def collect_sizes_local(apps, debug=False):
    sizes = {}
    try:
        result = run_subprocess(["bash", "-c", build_bulk_du_script()], timeout=600)
        if debug and (result.stderr or "").strip():
            print("  [debug] bulk du stderr: {}".format(
                (result.stderr or "").strip()[:300],
            ))
        sizes = parse_bulk_du_output(result.stdout or "")
    except (subprocess.TimeoutExpired, OSError) as exc:
        if debug:
            print("  [debug] bulk du failed: {}".format(exc))

    if not sizes:
        try:
            script = build_per_app_du_script(apps)
            result = run_subprocess(["bash", "-s"], input_text=script, timeout=600)
            sizes = parse_du_output(result.stdout or "")
        except (subprocess.TimeoutExpired, OSError) as exc:
            if debug:
                print("  [debug] per-app du failed: {}".format(exc))
            sizes = {}

    for app in apps:
        su = str(app.get("sys_user", "")).strip()
        if not su:
            continue
        ent = sizes.setdefault(su, {"files_size": "n/a", "db_size": "n/a"})
        if ent.get("files_size") not in (None, "", "n/a"):
            continue
        items = run_apm_disk(su, debug=debug)
        total_mb = sum_breakdown_mb(items)
        if total_mb is not None:
            ent["files_size"] = format_mb_display(total_mb)
    return sizes


def collect_sizes_remote(mode, server_ip, apps, ssh_user, cng_argv):
    if not apps:
        return {}
    script = build_per_app_du_script(apps)
    stdout, ok, detail = run_remote_script(
        mode, server_ip, script, ssh_user, cng_argv,
    )
    if not ok:
        print("  [warn] {} to {} failed: {}".format(mode, server_ip, detail[:200]))
        return {}
    return parse_du_output(stdout)


def app_url(app):
    cname = str(app.get("cname", "") or "").strip()
    if cname:
        return cname
    return str(app.get("app_fqdn", "") or app.get("url", "") or "").strip()


def server_location(srv):
    provider = str(srv.get("cloud", "") or srv.get("provider", "") or "").strip()
    region = str(
        srv.get("region", "") or srv.get("datacenter", "") or srv.get("zone", "") or ""
    ).strip()
    if provider and region:
        return "{}/{}".format(provider, region)
    return provider or region or "n/a"


def parse_size_mode(choice, default_digit):
    c = choice.strip().lower()
    if not c:
        c = default_digit
    by_name = {
        "api": "api", "local": "local", "cng": "cng", "ssh": "ssh", "skip": "skip",
    }
    by_digit = {
        "1": "api", "2": "local", "3": "cng", "4": "ssh", "5": "skip",
    }
    if c in by_name:
        return by_name[c]
    if c in by_digit:
        return by_digit[c]
    return "api"


def lookup_app_sizes(server_sizes, app):
    if not server_sizes or server_sizes == "SKIPPED":
        return server_sizes
    sys_user = str(app.get("sys_user", ""))
    label = str(app.get("label", "")).strip()
    entry = (
        server_sizes.get(sys_user)
        or server_sizes.get(label)
        or {}
    )
    return entry


def mb_to_gib(mb):
    try:
        return float(mb) / 1024.0
    except (TypeError, ValueError):
        return 0.0


def format_gib(mb):
    if mb is None:
        return "n/a"
    try:
        gib = float(mb) / 1024.0
    except (TypeError, ValueError):
        return "n/a"
    if gib >= 10:
        return "{:.1f} GiB".format(gib)
    if gib >= 1:
        return "{:.1f} GiB".format(gib)
    return "{:.2f} GiB".format(gib)


def parse_human_size_to_mb(text):
    """Convert du/apm output like 2.5G, 1800M, 2560K to MB."""
    if not text or text == "n/a":
        return None
    text = str(text).strip().upper()
    m = re.match(r"^(\d+(?:\.\d+)?)K$", text)
    if m:
        return float(m.group(1)) / 1024.0
    m = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?)(?:I?B)?$", text)
    if not m:
        return None
    val = float(m.group(1))
    unit = m.group(2) or "K"
    mult = {"K": 1.0 / 1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}
    return val * mult.get(unit, 1.0)


APM_DISK_LINE = re.compile(
    r"^\s*([\d.]+)\s+(GiB|MiB|KiB|TiB|G|M|K)\s+\[[# ]+\]\s+(/[^\s]*)\s*$",
    re.IGNORECASE,
)


def apm_unit_to_mb(val, unit):
    u = str(unit).lower().replace("ib", "").replace("b", "")
    if u in ("g",):
        return float(val) * 1024.0
    if u in ("m",):
        return float(val)
    if u in ("k",):
        return float(val) / 1024.0
    if u in ("t",):
        return float(val) * 1024.0 * 1024.0
    return float(val)


def apm_binary():
    for candidate in ("/usr/local/sbin/apm", shutil.which("apm") or ""):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return ""


def parse_apm_disk_output(stdout):
    items = []
    for line in (stdout or "").splitlines():
        m = APM_DISK_LINE.match(line.strip())
        if not m:
            continue
        items.append({
            "path": m.group(3).strip(),
            "size_mb": apm_unit_to_mb(m.group(1), m.group(2)),
        })
    return items


def run_apm_disk(sys_user, debug=False):
    """Cloudways APM disk breakdown (/usr/local/sbin/apm -s USER -d)."""
    apm = apm_binary()
    if not apm:
        return []
    try:
        result = run_subprocess([apm, "-s", sys_user, "-d"], timeout=180)
    except (subprocess.TimeoutExpired, OSError) as exc:
        if debug:
            print("  [debug] apm {}: {}".format(sys_user, exc))
        return []
    if debug and (result.stderr or "").strip():
        print("  [debug] apm {} stderr: {}".format(
            sys_user, (result.stderr or "").strip()[:200],
        ))
    if result.returncode != 0 and not (result.stdout or "").strip():
        return []
    return parse_apm_disk_output(result.stdout)


def resolve_app_base(sys_user):
    for base in (
        "/home/master/applications/{}".format(sys_user),
        "/home/{}.cloudwaysapps.com".format(sys_user),
    ):
        if os.path.isdir(base):
            return base
    return ""


def sum_breakdown_mb(items):
    total = sum((i.get("size_mb") or 0) for i in (items or []))
    return total if total > 0 else None


def content_to_breakdown_items(content):
    """Parse monitor/diskUsage content into [{path, size_mb}, ...]."""
    items = []
    for item in content or []:
        if not isinstance(item, dict):
            continue
        name = str(
            item.get("name") or item.get("label") or item.get("folder") or ""
        ).strip()
        if not name or name.lower() in ("total", "bw", "bandwidth"):
            continue
        mb = extract_size_mb(item.get("datapoint"))
        if mb is None:
            mb = extract_size_mb(item.get("size"))
        if mb is None:
            mb = extract_size_mb(item.get("value"))
        if mb is None:
            mb = extract_size_mb(item.get("usage"))
        if mb is None:
            continue
        path = name if name.startswith("/") else "/{}".format(name)
        items.append({"path": path, "size_mb": mb})
    return items


def breakdown_from_body(body):
    """Extract folder breakdown list from assorted API response shapes."""
    if isinstance(body, list):
        return content_to_breakdown_items(body)
    if not isinstance(body, dict):
        return []
    content = monitor_content_list(body)
    items = content_to_breakdown_items(content)
    if items:
        return items
    for key in ("folders", "directories", "breakdown", "data", "usage"):
        val = body.get(key)
        if isinstance(val, list):
            items = content_to_breakdown_items(val)
            if items:
                return items
    return []


def fetch_app_disk_breakdown_api(token, server_id, app_id, debug=False):
    """Folder-level disk breakdown for one app via v1 monitor API."""
    disk_paths = (
        ("/app/manage/diskUsage", {}),
        ("/app/monitor/diskUsage", {}),
        ("/app/disk_usage", {}),
    )
    for path, extra in disk_paths:
        params = {"server_id": server_id, "app_id": app_id}
        params.update(extra)
        code, body = api_get_v1(token, path, params)
        if debug:
            print("  [debug] breakdown {} {} -> {}".format(
                path, code, str(body)[:300],
            ))
        if code == 200:
            items = breakdown_from_body(body)
            if items:
                return items
        time.sleep(0.1)

    for summary_type in ("disk_usage", "disk", "webroot", "files", "file", "web"):
        content, body = app_monitor_summary(token, server_id, app_id, summary_type)
        items = content_to_breakdown_items(content)
        if items:
            return items
        items = breakdown_from_body(body)
        if items:
            return items
        time.sleep(0.12)

    for disk_type in ("files", "webroot", "disk", ""):
        params = {"server_id": server_id, "app_id": app_id}
        if disk_type:
            params["type"] = disk_type
        code, body = api_get_v1(token, "/app/manage/disk_usage", params)
        if code == 200:
            items = breakdown_from_body(body)
            if items:
                return items
        time.sleep(0.1)
    return []


def build_app_folder_du_script(sys_user, top_n):
    base = resolve_app_base(sys_user) or "/home/master/applications/{}".format(
        sys_user,
    )
    bq = shlex.quote(base)
    ph = shlex.quote(os.path.join(base, "public_html"))
    lines = [
        "set +e",
        "DU=/usr/bin/du",
        '[ -x "$DU" ] || DU=du',
        "base={bq}".format(bq=bq),
        'for d in "$base"/public_html "$base"/logs "$base"/tmp "$base"/private_html; do',
        '  [ -d "$d" ] || continue',
        '  sz=$($DU -sh "$d" 2>/dev/null | awk \'{print $1}\')',
        '  [ -n "$sz" ] && printf "%s\\t%s\\n" "$d" "$sz"',
        "done",
        "$DU -sh {ph}/.[!.]* {ph}/* 2>/dev/null | sort -hr | head -n {top}".format(
            ph=ph, top=int(top_n),
        ),
    ]
    return "\n".join(lines)


def parse_folder_du_output(stdout):
    items = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) == 2:
            left, right = parts[0].strip(), parts[1].strip()
            if re.match(r"^[\d.]", left):
                size, path = left, right
            else:
                path, size = left, right
        else:
            m = re.match(r"^(\S+)\s+(.+)$", line)
            if not m:
                continue
            size, path = m.group(1).strip(), m.group(2).strip()
        mb = parse_human_size_to_mb(size)
        if mb is None:
            continue
        if not path.startswith("/"):
            path = "/{}".format(path)
        items.append({"path": path, "size_mb": mb})
    return items


def is_public_html_path(path):
    p = str(path or "").rstrip("/")
    return p.endswith("/public_html") or p.endswith("public_html")


def build_public_html_deep_du_script(sys_user, top_n, depth=2):
    base = resolve_app_base(sys_user)
    if not base:
        return ""
    ph = os.path.join(base, "public_html")
    if not os.path.isdir(ph):
        return ""
    phq = shlex.quote(ph)
    depth = max(1, min(int(depth), 6))
    top_n = max(1, int(top_n))
    extra = top_n + 3
    return "\n".join([
        "set +e",
        "DU=/usr/bin/du",
        '[ -x "$DU" ] || DU=du',
        "PH={phq}".format(phq=phq),
        '[ -d "$PH" ] || exit 0',
        'OUT=$($DU -xh --max-depth={d} "$PH" 2>/dev/null | sort -hr | head -n {extra})'.format(
            d=depth, extra=extra,
        ),
        'if [ -n "$OUT" ]; then printf "%s\\n" "$OUT"; exit 0; fi',
        '$DU -h --max-depth={d} "$PH" 2>/dev/null | sort -hr | head -n {extra}'.format(
            d=depth, extra=extra,
        ),
    ])


def collect_public_html_deep_breakdown(sys_user, top_n, depth=2, debug=False):
    """du --max-depth=N under public_html (wp-content, uploads, etc.)."""
    base = resolve_app_base(sys_user)
    if not base:
        return []
    ph = os.path.join(base, "public_html")
    script = build_public_html_deep_du_script(sys_user, top_n, depth)
    if not script:
        return []
    try:
        result = run_subprocess(["bash", "-c", script], timeout=300)
    except (subprocess.TimeoutExpired, OSError) as exc:
        if debug:
            print("  [debug] public_html du {}: {}".format(sys_user, exc))
        return []
    if debug and not (result.stdout or "").strip():
        print("  [debug] public_html du {}: empty".format(sys_user))
    return filter_public_html_du_items(result.stdout or "", ph, top_n)


def filter_public_html_du_items(stdout, public_html_root, top_n):
    root = os.path.normpath(public_html_root)
    items = parse_folder_du_output(stdout)
    filtered = []
    for item in items:
        path = os.path.normpath(item.get("path", ""))
        if not path or path == root:
            continue
        if not path.startswith(root + os.sep):
            continue
        filtered.append(item)
    return sort_breakdown_items(filtered)[:top_n]


def collect_app_top_level_dirs(sys_user, debug=False):
    """logs/tmp/private_html from apm; skip public_html (handled by deep du)."""
    items = []
    for item in run_apm_disk(sys_user, debug=debug):
        path = item.get("path", "")
        if is_public_html_path(path):
            continue
        items.append(item)
    if items:
        return items
    base = resolve_app_base(sys_user) or "/home/master/applications/{}".format(
        sys_user,
    )
    bq = shlex.quote(base)
    script = "\n".join([
        "set +e", "DU=/usr/bin/du", '[ -x "$DU" ] || DU=du',
        "base={}".format(bq),
        'for d in "$base"/logs "$base"/tmp "$base"/private_html; do',
        '  [ -d "$d" ] || continue',
        '  sz=$($DU -sh "$d" 2>/dev/null | awk \'{print $1}\')',
        '  [ -n "$sz" ] && echo -e "$sz\\t$d"',
        "done",
    ])
    try:
        result = run_subprocess(["bash", "-c", script], timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        return []
    return [i for i in parse_folder_du_output(result.stdout or "") if i.get("size_mb", 0) > 0.01]


def collect_app_breakdown_local(sys_user, top_n=10, depth=2, debug=False):
    """App dirs + deep public_html folder tree (wp-content/uploads, etc.)."""
    if depth <= 0:
        items = run_apm_disk(sys_user, debug=debug)
        if items:
            return sort_breakdown_items(items)[:top_n]
    else:
        items = collect_app_top_level_dirs(sys_user, debug=debug)
        ph_items = collect_public_html_deep_breakdown(
            sys_user, top_n=top_n, depth=depth, debug=debug,
        )
        items = merge_breakdown_items(ph_items, items)
        if ph_items:
            items = sort_breakdown_items(items)[:top_n]
            if items:
                return items
    script = build_app_folder_du_script(sys_user, top_n)
    try:
        result = run_subprocess(["bash", "-s"], input_text=script, timeout=180)
    except (subprocess.TimeoutExpired, OSError) as exc:
        if debug:
            print("  [debug] folder du {}: {}".format(sys_user, exc))
        return []
    if debug and not (result.stdout or "").strip():
        print("  [debug] folder du {}: empty (base={})".format(
            sys_user, resolve_app_base(sys_user) or "?",
        ))
    return sort_breakdown_items(parse_folder_du_output(result.stdout or ""))[:top_n]


def collect_app_breakdown_remote(mode, server_ip, sys_user, top_n, ssh_user, cng_argv):
    script = build_app_folder_du_script(sys_user, top_n)
    stdout, ok, _ = run_remote_script(mode, server_ip, script, ssh_user, cng_argv)
    if not ok:
        return []
    return parse_folder_du_output(stdout)


def merge_breakdown_items(primary, fallback):
    """Prefer primary; fill missing paths from fallback."""
    by_path = {}
    for item in primary or []:
        by_path[item["path"]] = item
    for item in fallback or []:
        by_path.setdefault(item["path"], item)
    return list(by_path.values())


def sort_breakdown_items(items):
    return sorted(items, key=lambda x: x.get("size_mb") or 0, reverse=True)


def render_bar_chart(items, bar_width=26, limit=0):
    """Render APM-style disk bars for ranked paths."""
    ranked = sort_breakdown_items(items)
    if limit:
        ranked = ranked[:limit]
    if not ranked:
        print("  (no breakdown data)")
        return
    max_mb = max((i.get("size_mb") or 0) for i in ranked) or 1.0
    for item in ranked:
        mb = item.get("size_mb") or 0
        path = item.get("path", "/?")
        filled = int(round((mb / max_mb) * bar_width)) if max_mb else 0
        bar = "#" * filled + " " * (bar_width - filled)
        print("  {:>8}  [{}] {}".format(format_gib(mb), bar, path))


def app_total_mb_from_entry(entry):
    files_mb = parse_human_size_to_mb(entry.get("files_size", ""))
    db_mb = parse_human_size_to_mb(entry.get("db_size", ""))
    total = 0.0
    found = False
    for v in (files_mb, db_mb):
        if v is not None:
            total += v
            found = True
    return total if found else None


def render_app_totals_bar_chart(app_entries, bar_width=26):
    """Rank apps by total disk (files + db) with /sys_user paths."""
    rows = []
    for row in app_entries:
        mb = app_total_mb_from_entry(row)
        if mb is None:
            continue
        su = str(row.get("sys_user", "")).strip()
        path = "/{}".format(su) if su else "/?"
        rows.append({
            "path": path,
            "size_mb": mb,
            "label": row.get("app_label", ""),
            "files_size": row.get("files_size", "n/a"),
            "db_size": row.get("db_size", "n/a"),
        })
    render_bar_chart(rows, bar_width=bar_width)


def filter_servers_apps(servers, server_id=None, app_filters=None):
    """Filter servers/apps by server id and/or sys_user/label list."""
    app_filters = [a.strip().lower() for a in (app_filters or []) if a.strip()]
    out = []
    for srv in servers:
        sid = str(srv.get("id", ""))
        if server_id and sid != str(server_id):
            continue
        apps = srv.get("apps", [])
        if app_filters:
            filtered = []
            for app in apps:
                su = str(app.get("sys_user", "")).strip().lower()
                label = str(app.get("label", "")).strip().lower()
                app_id = str(app.get("id", "")).strip().lower()
                if (
                    su in app_filters
                    or label in app_filters
                    or app_id in app_filters
                    or any(f in su or f in label for f in app_filters)
                ):
                    filtered.append(app)
            if not filtered:
                continue
            srv = dict(srv)
            srv["apps"] = filtered
        out.append(srv)
    return out


def collect_breakdown_for_app(token, server_id, app, size_mode, server_ip,
                              ssh_user, cng_argv, top_n, depth=2, debug=False):
    sys_user = str(app.get("sys_user", "")).strip()
    app_id = str(app.get("id", "")).strip()
    items = []
    if size_mode in ("api", "local", "cng", "ssh"):
        if size_mode == "api" and app_id:
            items = fetch_app_disk_breakdown_api(
                token, server_id, app_id, debug=debug,
            )
        if size_mode == "local":
            items = collect_app_breakdown_local(
                sys_user, top_n=top_n, depth=depth, debug=debug,
            )
        elif size_mode in ("cng", "ssh"):
            items = collect_app_breakdown_remote(
                size_mode, server_ip, sys_user, top_n, ssh_user, cng_argv,
            )
        if size_mode == "api" and not items:
            local_sid = detect_local_server_id()
            if local_sid and str(server_id) == local_sid:
                local_items = collect_app_breakdown_local(
                    sys_user, top_n=top_n, depth=depth, debug=debug,
                )
                items = merge_breakdown_items(local_items, items)
    return sort_breakdown_items(items)[:top_n]


def parse_cli_args(argv):
    epilog = (
        "Run without downloading (on a Cloudways server, all apps, no API key):\n"
        "  {local}\n\n"
        "Run from anywhere with API (specific apps or account-wide):\n"
        "  {api}\n\n"
        "Omit --apps on a server to include every app on that machine."
    ).format(local=SCRIPT_CURL_LOCAL, api=SCRIPT_CURL_API)
    parser = argparse.ArgumentParser(
        description="Cloudways app inventory with optional per-app disk breakdown.",
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--email", help="Cloudways account email (or CW_EMAIL)")
    parser.add_argument("--api-key", help="Cloudways API key (or CW_API_KEY)")
    parser.add_argument(
        "--mode", choices=["api", "local", "cng", "ssh", "skip"],
        help="Size source: local=live du on this server (default with --breakdown here)",
    )
    parser.add_argument(
        "--breakdown", action="store_true",
        help="Show per-app folder disk breakdown (APM-style bars)",
    )
    parser.add_argument(
        "--apps", metavar="LIST",
        help="Comma-separated sys_user filter (default on server: all apps)",
    )
    parser.add_argument(
        "--server", metavar="ID",
        help="Limit to one server id (default on server: this server)",
    )
    parser.add_argument(
        "--this-server", action="store_true",
        help="Only apps on the current Cloudways server (auto when run on-server)",
    )
    parser.add_argument(
        "--top", type=int, default=15, metavar="N",
        help="Max folder lines per app (default: 15)",
    )
    parser.add_argument(
        "--depth", type=int, default=2, metavar="N",
        help="Folder depth under public_html (default: 2, e.g. wp-content/uploads)",
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Emit machine-readable JSON (breakdown or inventory)",
    )
    parser.add_argument(
        "--totals-only", action="store_true",
        help="Ranked /sys_user totals only (no per-folder drill-down)",
    )
    parser.add_argument(
        "--debug", action="store_true",
        help="Show du/apm diagnostics when sizes are missing",
    )
    return parser.parse_args(argv)


def resolve_credentials(args, required=True):
    email = (args.email or os.environ.get("CW_EMAIL", "")).strip()
    api_key = (args.api_key or os.environ.get("CW_API_KEY", "")).strip()
    if not email and required:
        email = input("\nEmail address : ").strip()
    if not api_key and required:
        api_key = getpass.getpass("API key       : ").strip()
    if required and (not email or not api_key):
        print("[ERROR] Email and API key are required.")
        print("Set CW_EMAIL and CW_API_KEY, or run on-server with:")
        print("  {}".format(SCRIPT_CURL_LOCAL))
        sys.exit(1)
    return email, api_key


def apply_on_server_defaults(args, on_cw, local_sid):
    """When run on a Cloudways server, default to all apps here + local du."""
    if not on_cw:
        return args
    if args.breakdown or args.totals_only:
        if args.mode == "api":
            args.mode = "local"
        elif not args.mode:
            args.mode = "local"
    if args.this_server or (args.breakdown and not args.server and not args.apps):
        args.this_server = True
        if local_sid:
            args.server = local_sid
    return args


def resolve_size_mode(args, on_cw):
    if args.mode:
        return args.mode
    default_digit = "2" if on_cw else "1"
    print("\nSize collection method:")
    print("  1) api   -- files from monitor type=db; db from API or local du on this server")
    print("  2) local -- du -sch THIS server only")
    print("  3) cng   -- du all servers via cw-proxy cng <ip>")
    print("  4) ssh   -- du all servers via ssh root@public_ip")
    print("  5) skip")
    choice = input(
        "Choose [{}] (1-5 or api/local/cng/ssh/skip) : ".format(default_digit)
    ).strip()
    return parse_size_mode(choice, default_digit)


def run_breakdown_report(token, servers, size_mode, top_n, ssh_user, cng_argv,
                         totals_only=False, as_json=False, depth=2):
    debug = os.environ.get("MONITOR_DEBUG", "").strip() == "1"
    report = {"apps": []}
    for srv in servers:
        sid = str(srv.get("id", ""))
        ip = str(srv.get("public_ip", ""))
        apps = srv.get("apps", [])
        sizes = {}
        if size_mode == "api":
            sizes = collect_sizes_api_for_server(token, sid, apps)
        elif size_mode == "local":
            sizes = collect_sizes_local(apps)
        elif size_mode in ("cng", "ssh"):
            sizes = collect_sizes_remote(size_mode, ip, apps, ssh_user, cng_argv)

        for app in apps:
            su = str(app.get("sys_user", "")).strip()
            app_id = str(app.get("id", "")).strip()
            entry = lookup_app_sizes(sizes, app) if sizes else {}
            app_rec = {
                "server_id": sid,
                "server_ip": ip,
                "app_id": app_id,
                "app_label": str(app.get("label", "")),
                "sys_user": su,
                "files_size": entry.get("files_size", "n/a"),
                "db_size": entry.get("db_size", "n/a"),
                "folders": [],
            }
            if not totals_only:
                folders = collect_breakdown_for_app(
                    token, sid, app, size_mode, ip, ssh_user, cng_argv,
                    top_n, depth=depth, debug=debug,
                )
                app_rec["folders"] = [
                    {"path": f["path"], "size_mb": f["size_mb"],
                     "size": format_gib(f["size_mb"])}
                    for f in folders
                ]
            report["apps"].append(app_rec)

    if as_json:
        print(json.dumps(report, indent=2))
        return report

    print("\n=== App disk breakdown ===\n")
    if totals_only:
        render_app_totals_bar_chart(report["apps"])
    else:
        for rec in report["apps"]:
            header = "{} ({})  files={}  db={}".format(
                rec["sys_user"], rec.get("app_label", ""),
                rec["files_size"], rec["db_size"],
            )
            print(header)
            render_bar_chart(
                [{"path": f["path"], "size_mb": f["size_mb"]} for f in rec["folders"]],
                limit=top_n,
            )
            print()
    return report


def collect_rows(servers, sizes_by_server):
    rows = []
    for srv in servers:
        server_id = str(srv.get("id", ""))
        server_label = str(srv.get("label", ""))
        server_ip = str(srv.get("public_ip", ""))
        location = server_location(srv)
        server_sizes = sizes_by_server.get(server_id)
        for app in srv.get("apps", []):
            sys_user = str(app.get("sys_user", ""))
            if server_sizes == "SKIPPED":
                files_sz = db_sz = "skipped"
            elif server_sizes is None:
                files_sz = db_sz = "unavailable"
            else:
                entry = lookup_app_sizes(server_sizes, app)
                files_sz = entry.get("files_size", "n/a")
                db_sz = entry.get("db_size", "n/a")
            rows.append({
                "server_id": server_id,
                "server_label": server_label,
                "server_ip": server_ip,
                "server_location": location,
                "app_id": str(app.get("id", "")),
                "app_label": str(app.get("label", "")),
                "app_type": str(app.get("application", "")),
                "app_url": app_url(app),
                "sys_user": sys_user,
                "is_staging": "yes" if str(app.get("is_staging", "0")) == "1" else "no",
                "files_size": files_sz,
                "db_size": db_sz,
            })
    return rows


def main():
    args = parse_cli_args(sys.argv[1:])
    app_filters = []
    if args.apps:
        app_filters = [a.strip() for a in args.apps.split(",") if a.strip()]

    local_sid = detect_local_server_id()
    on_cw = on_cloudways_server()
    args = apply_on_server_defaults(args, on_cw, local_sid)

    print("=" * 60)
    print("  Cloudways Account App Inventory (read-only)")
    print("  Python {}  build {}".format(sys.version.split()[0], SCRIPT_BUILD))
    print("=" * 60)

    if can_run_without_api(args, on_cw):
        apps = filter_local_apps(discover_local_apps(), app_filters)
        if not apps:
            print("[ERROR] No apps matched under /home/master/applications/.")
            if app_filters:
                print("  Filter: {}".format(", ".join(app_filters)))
            sys.exit(1)
        print("\n[local] Server {} — {} app(s) on this machine (apm + du, no API)".format(
            local_sid or "?", len(apps),
        ))
        if os.environ.get("CW_EMAIL") or os.environ.get("CW_API_KEY"):
            print("  (API credentials ignored on-server; OAuth is blocked from here.)")
        totals_only = args.totals_only or not args.breakdown
        run_local_server_breakdown(
            apps, local_sid, args.top, totals_only=totals_only, as_json=args.json,
            debug=args.debug, depth=args.depth,
        )
        if not args.json:
            print("=" * 60)
        return

    email, api_key = resolve_credentials(args, required=True)
    print()
    token = fetch_token(email, api_key)
    print("\n[1] Fetching server + app list ...")
    servers = fetch_all_servers(token)
    servers = filter_servers_apps(servers, server_id=args.server, app_filters=app_filters)
    if not servers:
        print("[ERROR] No servers/apps matched filters.")
        sys.exit(1)
    print("    {} server(s), {} app(s) after filter.".format(
        len(servers),
        sum(len(s.get("apps", [])) for s in servers),
    ))

    on_cw = bool(local_sid)
    size_mode = resolve_size_mode(args, on_cw)
    if size_mode == "cng" and not shutil.which("cng"):
        print("[ERROR] `cng` not found. Use option 1 (api) on cw-proxy or SSH to cw-proxy.")
        sys.exit(1)

    ssh_user = "root"
    cng_argv = ["cng"]
    if size_mode == "ssh":
        ssh_user = os.environ.get("SSH_USER", "").strip() or "root"
        if not args.mode:
            ssh_user = input("SSH user [root] : ").strip() or "root"
    if size_mode == "cng":
        cng_prefix = (
            os.environ.get("CNG_CMD", "").strip()
            or (not args.mode and (input("Cng command [cng] : ").strip() or "cng"))
            or "cng"
        )
        cng_argv = shlex.split(cng_prefix)

    if args.breakdown or app_filters:
        totals_only = args.totals_only or (bool(app_filters) and not args.breakdown)
        run_breakdown_report(
            token, servers, size_mode, args.top, ssh_user, cng_argv,
            totals_only=totals_only,
            as_json=args.json,
            depth=args.depth,
        )
        if not args.json:
            print("=" * 60)
        return

    sizes_by_server = {}

    if size_mode == "api":
        print("\n[2] Collecting sizes via v1 monitor API ...")
        print("    files: server/monitor/summary type=db (app disk; Cloudways naming)")
        print("    db:    du /var/lib/mysql on this server if API has no MySQL metric")
        for srv in servers:
            sid = str(srv.get("id", ""))
            apps = srv.get("apps", [])
            print("    {} ... ".format(sid), end="")
            sys.stdout.flush()
            sizes = collect_sizes_api_for_server(token, sid, apps)
            if sizes:
                sizes_by_server[sid] = sizes
                print("ok ({} app(s))".format(len(sizes)))
            else:
                sizes_by_server[sid] = None
                print("FAILED")
            time.sleep(0.35)

        fill_missing_sizes_via_local_du(servers, sizes_by_server, local_sid)

    elif size_mode == "local":
        if not local_sid:
            print("[ERROR] local mode requires /home/master/applications.")
            sys.exit(1)
        target = next((s for s in servers if str(s.get("id")) == local_sid), None)
        if target is None:
            print("[ERROR] Server id {} not in account.".format(local_sid))
            sys.exit(1)
        print("\n[2] Collecting sizes locally for server {} ...".format(local_sid))
        apps = target.get("apps", [])
        sizes = collect_sizes_local(apps)
        sizes_by_server[local_sid] = sizes if sizes else None
        for sid in servers:
            if str(sid.get("id")) != local_sid:
                sizes_by_server[str(sid.get("id"))] = None
        print("    ok ({} app(s) sized)".format(len(sizes)))

    elif size_mode in ("cng", "ssh"):
        if size_mode == "cng":
            print("\n[2] Collecting sizes via cng (du -sch) ...")
        else:
            print("\n[2] Collecting sizes via ssh (du -sch) ...")
        for srv in servers:
            sid = str(srv.get("id", ""))
            ip = str(srv.get("public_ip", ""))
            apps = srv.get("apps", [])
            print("    {} ({}) ... ".format(sid, ip), end="")
            sys.stdout.flush()
            sizes = collect_sizes_remote(
                size_mode, ip, apps, ssh_user, cng_argv,
            )
            if sizes:
                sizes_by_server[sid] = sizes
                print("ok ({} app(s))".format(len(sizes)))
            else:
                sizes_by_server[sid] = None
                print("FAILED")

    else:
        sizes_by_server = {str(s.get("id", "")): "SKIPPED" for s in servers}

    rows = collect_rows(servers, sizes_by_server)
    print("\n    {} app(s) total.\n".format(len(rows)))

    if rows:
        headers = [
            "server_id", "server_ip", "server_location", "app_id",
            "app_label", "app_type", "app_url", "files_size", "db_size",
            "is_staging",
        ]
        widths = {h: max(len(h), max(len(r[h]) for r in rows)) for h in headers}
        line = "  ".join(h.ljust(widths[h]) for h in headers)
        print(line)
        print("-" * len(line))
        for r in rows:
            print("  ".join(r[h].ljust(widths[h]) for h in headers))

    stamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    csvpath = os.path.join(os.getcwd(), "cloudways_app_inventory_{}.csv".format(stamp))
    with open(csvpath, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "server_id", "server_label", "server_ip", "server_location",
            "app_id", "app_label", "app_type", "app_url",
            "sys_user", "is_staging", "files_size", "db_size",
        ])
        writer.writeheader()
        writer.writerows(rows)

    print("\nCSV written to: {}".format(os.path.abspath(csvpath)))
    print("=" * 60)


if __name__ == "__main__":
    main()
