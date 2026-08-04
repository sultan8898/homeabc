#!/usr/bin/env python3
"""
Cloudways Account App Inventory (v2 API)

Read-only. Lists every application on the account with per-app du -sch sizes.

Requires Python 3.5+ (cw-proxy ships an older python3; this script avoids 3.6+ syntax).

Stable raw URL (pin by commit; branch URL can lag on GitHub CDN):
    python3 <(curl -fsSL 'https://raw.githubusercontent.com/sultan8898/homeabc/95a0eeb/list_all_apps.py')

Or download then run (best if your terminal breaks long URLs):
    curl -fsSL -o /tmp/list_all_apps.py \\
      'https://raw.githubusercontent.com/sultan8898/homeabc/95a0eeb/list_all_apps.py'
    python3 /tmp/list_all_apps.py
"""

import base64
import csv
import glob
import os
import re
import sys
import getpass
import shutil
import subprocess
import shlex
from datetime import datetime, timedelta

import requests

if sys.version_info < (3, 5):
    sys.exit(
        "Python 3.5+ required. On cw-proxy try: python3 --version\n"
        "If only 2.7 is installed, ask ops to enable python3.5+ or run from an app server."
    )

API_BASE = "https://api.cloudways.com/api/v2"
TOKEN_TTL = 3600
SCRIPT_BUILD = "py35-95a0eeb"

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
            API_BASE + "/oauth/access_token",
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
        resp = requests.get(
            API_BASE + "/server", headers=auth_headers(token), timeout=60,
        )
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
        files_h = parts[1].strip()
        db_h = parts[2].strip()
        if not sys_user:
            continue
        sizes[sys_user] = {
            "files_size": files_h or "n/a",
            "db_size": db_h or "n/a",
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
        detail = err or "exit {}".format(result.returncode)
        return out, False, detail
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


def parse_size_mode(choice, default_digit, on_cloudways_server):
    c = choice.strip().lower()
    if not c:
        c = default_digit
    by_name = {"local": "local", "cng": "cng", "ssh": "ssh", "skip": "skip"}
    by_digit = {"1": "local", "2": "cng", "3": "ssh", "4": "skip"}
    if c in by_name:
        return by_name[c]
    if c in by_digit:
        return by_digit[c]
    if on_cloudways_server:
        return "local"
    return "cng"


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
                entry = server_sizes.get(sys_user) or {}
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
    print("  Cloudways Account App Inventory (v2 API, read-only)")
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
    default_size = "1" if on_cw else "2"
    print("\nSize collection method:")
    print("  1) local -- du on THIS server only (other servers: unavailable in CSV)")
    print("  2) cng   -- ALL servers via cw-proxy: cng <server_ip> (not on app servers)")
    print("  3) ssh   -- ALL servers: ssh root@<public_ip> each (cw-proxy or fleet SSH)")
    print("  4) skip")
    if on_cw:
        print(
            "\n  Note: you are on Cloudways server id {}. "
            "Option 1 only runs du here. For all {} servers, use cw-proxy (cng) "
            "or option 3 ssh if this host can reach every server IP.".format(
                local_sid, len(servers),
            )
        )
    choice = input(
        "Choose [{}] (1-4 or local/cng/ssh/skip) : ".format(default_size)
    ).strip()

    size_mode = parse_size_mode(choice, default_size, on_cw)
    if size_mode == "cng" and not shutil.which("cng"):
        print(
            "[ERROR] `cng` is not on this host (expected on cw-proxy, not on app servers).\n"
            "  - All servers: SSH to cw-proxy and run again, choose cng (2).\n"
            "  - This server only: choose local (1).\n"
            "  - All servers from here: choose ssh (3) if root SSH to each public_ip works."
        )
        sys.exit(1)
    sizes_by_server = {}

    if size_mode == "local":
        if not local_sid:
            print("[ERROR] local mode requires /home/master/applications (not on a Cloudways server).")
            sys.exit(1)
        target = next((s for s in servers if str(s.get("id")) == local_sid), None)
        if target is None:
            print("[ERROR] Detected server id {} not in API account list.".format(local_sid))
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
            print("\n[2] Collecting sizes via cng (per-app du -sch) ...")
        else:
            print("\n[2] Collecting sizes via ssh (per-app du -sch) ...")
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
                print("FAILED (sizes will show 'unavailable')")
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
