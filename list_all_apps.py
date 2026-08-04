#!/usr/bin/env python3
"""
Cloudways Account App Inventory (v2 API)

Read-only. Lists every application on the account with:
  server ID, server label, server IP, server location (region/provider),
  app ID, app label, app type, app URL (custom domain if set, else the
  cloudwaysapps.com URL), sys_user, staging flag, file size, DB size.

Sizes: the Cloudways API does not expose per-app disk usage, so sizes are
collected on each server with du (human-readable):

  files -> du -sh /home/master/applications/<sys_user>
  db    -> du -sh /var/lib/mysql/<mysql_db_name>   (API field, else sys_user)

Collection modes:
  local  -- run on a Cloudways app server as root (no SSH; current server only)
  cng    -- from cw-proxy: `cng <server_ip> '<remote du commands>'` (recommended
            when you SSH to cw-proxy as sultan and use cng to jump to servers)
  ssh    -- direct SSH to each server public IP (root + key from your machine)

Apps on servers you cannot reach show "unavailable" in the size columns.
Merge CSVs from multiple runs if needed.

Writes a CSV next to the console output. No changes are made to any server or app.

Usage on cw-proxy (after SSH):
    python3 list_all_apps.py
    # choose size method cng when prompted

Usage on a single Cloudways server as root:
    python3 list_all_apps.py
    # choose local when prompted
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
from pathlib import Path

import requests

API_BASE  = "https://api.cloudways.com/api/v2"
TOKEN_TTL = 3600

_token_cache: dict = {"token": None, "expires_at": None}


def fetch_token(email: str, api_key: str) -> str:
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
            f"{API_BASE}/oauth/access_token",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            json={"email": email, "api_key": api_key},
            timeout=30,
        )
        resp.raise_for_status()
        token = resp.json().get("access_token")
        if not token:
            print(f"[ERROR] No access_token in response: {resp.text[:300]}")
            sys.exit(1)
    except requests.RequestException as e:
        print(f"[ERROR] OAuth request failed: {e}")
        sys.exit(1)

    _token_cache["token"]      = token
    _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
    print("  [token] Token obtained.")
    return token


def auth_headers(token: str) -> dict:
    return {"Accept": "application/json", "Authorization": f"Bearer {token}"}


def fetch_all_servers(token: str) -> list:
    try:
        resp = requests.get(f"{API_BASE}/server", headers=auth_headers(token), timeout=60)
        resp.raise_for_status()
        return resp.json().get("servers", [])
    except requests.RequestException as e:
        print(f"[ERROR] Failed to fetch server list: {e}")
        sys.exit(1)


def detect_local_server_id() -> str:
    """Parse server_id from nginx configs when run on a Cloudways server."""
    try:
        for conf in glob.glob("/home/master/applications/*/conf/server.nginx"):
            text = Path(conf).read_text(errors="ignore")
            m = re.search(r"[a-z]+-(\d+)-\d+\.cloudwaysapps\.com", text)
            if m:
                return m.group(1)
    except OSError:
        pass
    return ""


def build_per_app_du_script(apps: list) -> str:
    """
    Remote bash: one line per app with tab-separated sys_user, files_h, db_h.
    Per app: du -sch on the app tree (total line) and on the MySQL datadir.
    """
    lines = ["set +e"]
    for app in apps:
        sys_user = str(app.get("sys_user", "")).strip()
        if not sys_user:
            continue
        db_name = str(app.get("mysql_db_name", "") or sys_user).strip()
        app_dir = f"/home/master/applications/{sys_user}"
        db_dir  = f"/var/lib/mysql/{db_name}"
        su = shlex.quote(sys_user)
        ad = shlex.quote(app_dir)
        dd = shlex.quote(db_dir)
        lines.append(
            f"fu=$(du -sch {ad} 2>/dev/null | awk '/^total/{{print $1}}'); "
            f"db=$(du -sch {dd} 2>/dev/null | awk '/^total/{{print $1}}'); "
            f"printf '%s\\t%s\\t%s\\n' {su} \"$fu\" \"$db\""
        )
    return "\n".join(lines)


def parse_du_output(stdout: str) -> dict:
    """{sys_user: {files_size, db_size}} from remote script output."""
    sizes: dict = {}
    for line in stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        sys_user, files_h, db_h = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if not sys_user:
            continue
        sizes[sys_user] = {
            "files_size": files_h or "n/a",
            "db_size":    db_h or "n/a",
        }
    return sizes


def run_remote_script(
    mode: str, server_ip: str, script: str, ssh_user: str, cng_argv: list,
) -> tuple:
    """Run script on server via cng or ssh. Returns (stdout, ok, detail)."""
    b64 = base64.b64encode(script.encode()).decode()
    remote = f"echo {shlex.quote(b64)} | base64 -d | bash"
    if mode == "cng":
        cmd = cng_argv + [server_ip, remote]
    else:
        cmd = [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new",
            f"{ssh_user}@{server_ip}",
            remote,
        ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=300,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        return "", False, str(e)

    err = result.stderr.strip()
    if result.returncode != 0 and not result.stdout.strip():
        return result.stdout, False, err or f"exit {result.returncode}"
    return result.stdout, True, err


def collect_sizes_local(apps: list) -> dict:
    script = build_per_app_du_script(apps)
    try:
        result = subprocess.run(
            ["bash", "-s"],
            input=script,
            capture_output=True, text=True, timeout=300,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"  [warn] local du failed: {e}")
        return {}
    return parse_du_output(result.stdout)


def collect_sizes_remote(
    mode: str,
    server_ip: str,
    apps: list,
    ssh_user: str,
    cng_argv: list,
) -> dict:
    if not apps:
        return {}
    script = build_per_app_du_script(apps)
    stdout, ok, detail = run_remote_script(
        mode, server_ip, script, ssh_user, cng_argv,
    )
    if not ok:
        print(f"  [warn] {mode} to {server_ip} failed: {detail[:200]}")
        return {}
    return parse_du_output(stdout)


def app_url(app: dict) -> str:
    cname = str(app.get("cname", "") or "").strip()
    if cname:
        return cname
    return str(app.get("app_fqdn", "") or app.get("url", "") or "").strip()


def server_location(srv: dict) -> str:
    provider = str(srv.get("cloud", "") or srv.get("provider", "") or "").strip()
    region   = str(srv.get("region", "") or srv.get("datacenter", "")
                   or srv.get("zone", "") or "").strip()
    if provider and region:
        return f"{provider}/{region}"
    return provider or region or "n/a"


def collect_rows(servers: list, sizes_by_server: dict) -> list:
    rows = []
    for srv in servers:
        server_id    = str(srv.get("id", ""))
        server_label = str(srv.get("label", ""))
        server_ip    = str(srv.get("public_ip", ""))
        location     = server_location(srv)
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
                db_sz    = entry.get("db_size", "n/a")
            rows.append({
                "server_id":       server_id,
                "server_label":    server_label,
                "server_ip":       server_ip,
                "server_location": location,
                "app_id":          str(app.get("id", "")),
                "app_label":       str(app.get("label", "")),
                "app_type":        str(app.get("application", "")),
                "app_url":         app_url(app),
                "sys_user":        sys_user,
                "is_staging":      "yes" if str(app.get("is_staging", "0")) == "1" else "no",
                "files_size":      files_sz,
                "db_size":         db_sz,
            })
    return rows


def main():
    print("=" * 60)
    print("  Cloudways Account App Inventory (v2 API, read-only)")
    print("=" * 60)

    email   = input("\nEmail address : ").strip()
    api_key = getpass.getpass("API key       : ").strip()
    if not email or not api_key:
        print("[ERROR] Email and API key are required.")
        sys.exit(1)

    print()
    token   = fetch_token(email, api_key)
    print("\n[1] Fetching server + app list ...")
    servers = fetch_all_servers(token)
    print(f"    {len(servers)} server(s) found.")

    local_sid = detect_local_server_id()
    default_size = "1" if local_sid else "2"
    print("\nSize collection method:")
    print("  1) local -- du on THIS server only (run as root on a Cloudways server)")
    print("  2) cng   -- from cw-proxy: cng <server_ip> per server (recommended on proxy)")
    print("  3) ssh   -- ssh root@<public_ip> per server")
    print("  4) skip")
    choice = input(f"Choose [{default_size}] : ").strip() or default_size

    size_mode = {"1": "local", "2": "cng", "3": "ssh", "4": "skip"}.get(choice, "cng")
    sizes_by_server: dict = {}

    if size_mode == "local":
        if not local_sid:
            print("[ERROR] local mode requires /home/master/applications (not on a Cloudways server).")
            sys.exit(1)
        target = next((s for s in servers if str(s.get("id")) == local_sid), None)
        if target is None:
            print(f"[ERROR] Detected server id {local_sid} not in API account list.")
            sys.exit(1)
        print(f"\n[2] Collecting sizes locally for server {local_sid} ...")
        apps = target.get("apps", [])
        sizes = collect_sizes_local(apps)
        sizes_by_server[local_sid] = sizes if sizes else None
        for sid in servers:
            if str(sid.get("id")) != local_sid:
                sizes_by_server[str(sid.get("id"))] = None
        print(f"    ok ({len(sizes)} app(s) sized)")
    elif size_mode in ("cng", "ssh"):
        ssh_user = "root"
        cng_argv = ["cng"]
        if size_mode == "ssh":
            ssh_user = input("SSH user [root] : ").strip() or "root"
        if size_mode == "cng":
            if not shutil.which("cng"):
                print("[ERROR] `cng` not found in PATH. Run this from cw-proxy or use ssh mode.")
                sys.exit(1)
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
            ip  = str(srv.get("public_ip", ""))
            apps = srv.get("apps", [])
            print(f"    {sid} ({ip}) ... ", end="", flush=True)
            sizes = collect_sizes_remote(
                size_mode, ip, apps, ssh_user, cng_argv,
            )
            if sizes:
                sizes_by_server[sid] = sizes
                print(f"ok ({len(sizes)} app(s))")
            else:
                sizes_by_server[sid] = None
                print("FAILED (sizes will show 'unavailable')")
    else:
        sizes_by_server = {str(s.get("id", "")): "SKIPPED" for s in servers}

    rows = collect_rows(servers, sizes_by_server)
    print(f"\n    {len(rows)} app(s) total.\n")

    if rows:
        headers = ["server_id", "server_ip", "server_location", "app_id",
                   "app_label", "app_type", "app_url", "files_size", "db_size",
                   "is_staging"]
        widths = {h: max(len(h), max(len(r[h]) for r in rows)) for h in headers}
        line = "  ".join(h.ljust(widths[h]) for h in headers)
        print(line)
        print("-" * len(line))
        for r in rows:
            print("  ".join(r[h].ljust(widths[h]) for h in headers))

    stamp   = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    csvpath = Path.cwd() / f"cloudways_app_inventory_{stamp}.csv"
    with open(csvpath, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "server_id", "server_label", "server_ip", "server_location",
            "app_id", "app_label", "app_type", "app_url",
            "sys_user", "is_staging", "files_size", "db_size",
        ])
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nCSV written to: {csvpath.resolve()}")
    print("=" * 60)


if __name__ == "__main__":
    main()
