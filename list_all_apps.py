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

Python 3.5+ (cw-proxy).

curl (pin by commit after push):
  curl -fsSL -o /tmp/list_all_apps.py \\
    'https://raw.githubusercontent.com/sultan8898/homeabc/<commit>/list_all_apps.py'
  python3 /tmp/list_all_apps.py
"""

import base64
import csv
import glob
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
SCRIPT_BUILD = "api-db-is-files-du-mysql"

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
    try:
        resp = requests.post(
            API_V2 + "/oauth/access_token",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            json={"email": email, "api_key": api_key},
            timeout=30,
        )
        resp.raise_for_status()
        token = resp.json().get("access_token")
        if not token:
            print("[ERROR] No access_token in response: {}".format(resp.text[:300]))
            sys.exit(1)
    except requests.RequestException as e:
        print("[ERROR] OAuth request failed: {}".format(e))
        sys.exit(1)

    _token_cache["token"] = token
    _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
    print("  [token] Token obtained.")
    return token


def auth_headers(token):
    return {"Accept": "application/json", "Authorization": "Bearer {}".format(token)}


def fetch_all_servers(token):
    try:
        resp = requests.get(API_V2 + "/server", headers=auth_headers(token), timeout=60)
        resp.raise_for_status()
        return resp.json().get("servers", [])
    except requests.RequestException as e:
        print("[ERROR] Failed to fetch server list: {}".format(e))
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


def build_per_app_du_script(apps):
    lines = ["set +e"]
    for app in apps:
        sys_user = str(app.get("sys_user", "")).strip()
        if not sys_user:
            continue
        db_name = str(app.get("mysql_db_name", "") or sys_user).strip()
        app_dir = "/home/master/applications/{}".format(sys_user)
        db_dir = "/var/lib/mysql/{}".format(db_name)
        su = shlex.quote(sys_user)
        ad = shlex.quote(app_dir)
        dd = shlex.quote(db_dir)
        lines.append(
            "fu=$(du -sch {ad} 2>/dev/null | awk '/^total/{{print $1}}'); "
            "db=$(du -sch {dd} 2>/dev/null | awk '/^total/{{print $1}}'); "
            "printf '%s\\t%s\\t%s\\n' {su} \"$fu\" \"$db\"".format(
                ad=ad, dd=dd, su=su,
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


def collect_sizes_local(apps):
    script = build_per_app_du_script(apps)
    try:
        result = run_subprocess(["bash", "-s"], input_text=script)
    except (subprocess.TimeoutExpired, OSError) as e:
        print("  [warn] local du failed: {}".format(e))
        return {}
    return parse_du_output(result.stdout or "")


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
    print("=" * 60)
    print("  Cloudways Account App Inventory (read-only)")
    print("  Python {}  build {}".format(sys.version.split()[0], SCRIPT_BUILD))
    print("=" * 60)

    email = input("\nEmail address : ").strip()
    api_key = getpass.getpass("API key       : ").strip()
    if not email or not api_key:
        print("[ERROR] Email and API key are required.")
        sys.exit(1)

    print()
    token = fetch_token(email, api_key)
    print("\n[1] Fetching server + app list ...")
    servers = fetch_all_servers(token)
    print("    {} server(s) found.".format(len(servers)))

    local_sid = detect_local_server_id()
    on_cw = bool(local_sid)
    default_size = "2" if on_cw else "1"

    print("\nSize collection method:")
    print("  1) api   -- files from monitor type=db; db from API or local du on this server")
    print("  2) local -- du -sch THIS server only")
    print("  3) cng   -- du all servers via cw-proxy cng <ip>")
    print("  4) ssh   -- du all servers via ssh root@public_ip")
    print("  5) skip")
    if on_cw:
        print(
            "\n  Note: on server id {} option 2 = local du only. "
            "Option 1 = API for all {} servers.".format(local_sid, len(servers))
        )

    choice = input(
        "Choose [{}] (1-5 or api/local/cng/ssh/skip) : ".format(default_size)
    ).strip()

    size_mode = parse_size_mode(choice, default_size)
    if size_mode == "cng" and not shutil.which("cng"):
        print("[ERROR] `cng` not found. Use option 1 (api) on cw-proxy or SSH to cw-proxy.")
        sys.exit(1)

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
        ssh_user = "root"
        cng_argv = ["cng"]
        if size_mode == "ssh":
            ssh_user = input("SSH user [root] : ").strip() or "root"
        if size_mode == "cng":
            cng_prefix = (
                os.environ.get("CNG_CMD", "").strip()
                or input("Cng command [cng] : ").strip()
                or "cng"
            )
            cng_argv = shlex.split(cng_prefix)
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
