#!/usr/bin/env python3
"""
Check SSH/SFTP whitelist coverage across all Cloudways servers (API v1).

Endpoints:
  POST /oauth/access_token
  GET  /server
  GET  /security/whitelisted?server_id=<id>

Credentials: CLOUDWAYS_EMAIL and CLOUDWAYS_API_KEY, or interactive prompt.

Examples:
  python3 cw_check_ssh_whitelist.py --ips 96.126.106.125,50.116.41.217
  python3 cw_check_ssh_whitelist.py --ips-file ips.txt
  python3 cw_check_ssh_whitelist.py   # prompts for IPs (one per line)
"""

from __future__ import annotations

import argparse
import getpass
import ipaddress
import os
import sys
import time
from datetime import datetime, timedelta
from typing import Any

import requests

API_BASE = "https://api.cloudways.com/api/v1"
TOKEN_TTL = 3600
RATE_SLEEP = 0.35

DEFAULT_CHECK_IPS = [
    "96.126.106.125",
    "50.116.41.217",
    "192.155.90.179",
    "192.81.129.227",
    "198.58.111.80",
    "139.162.220.143",
]

_token_cache: dict[str, Any] = {"token": None, "expires_at": None}


def fetch_token(email: str, api_key: str) -> str:
    now = datetime.utcnow()
    if (
        _token_cache["token"]
        and _token_cache["expires_at"]
        and now < _token_cache["expires_at"]
    ):
        return _token_cache["token"]

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
    except requests.RequestException as exc:
        print(f"[ERROR] OAuth request failed: {exc}")
        sys.exit(1)

    _token_cache["token"] = token
    _token_cache["expires_at"] = now + timedelta(seconds=TOKEN_TTL - 60)
    return token


def auth_headers(token: str) -> dict[str, str]:
    return {"Accept": "application/json", "Authorization": f"Bearer {token}"}


def parse_ip_list(raw: Any) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, str):
        raw = raw.strip()
        return [raw] if raw else []
    if isinstance(raw, list):
        out: list[str] = []
        for item in raw:
            if item is None:
                continue
            s = str(item).strip()
            if s:
                out.append(s)
        return out
    return []


def normalize_whitelist_entry(entry: str) -> str:
    """Return host portion for comparison (drops /CIDR if present)."""
    entry = entry.strip()
    if not entry:
        return entry
    if "/" in entry:
        try:
            return str(ipaddress.ip_interface(entry).ip)
        except ValueError:
            return entry.split("/", 1)[0]
    return entry


def fetch_servers(token: str) -> list[dict[str, Any]]:
    try:
        resp = requests.get(f"{API_BASE}/server", headers=auth_headers(token), timeout=120)
        resp.raise_for_status()
    except requests.RequestException as exc:
        print(f"[ERROR] Failed to fetch servers: {exc}")
        sys.exit(1)
    servers = resp.json().get("servers", [])
    if not isinstance(servers, list):
        print("[ERROR] Unexpected /server response shape.")
        sys.exit(1)
    return servers


def fetch_ssh_whitelist(server_id: str, token: str) -> dict[str, Any]:
    try:
        resp = requests.get(
            f"{API_BASE}/security/whitelisted",
            headers=auth_headers(token),
            params={"server_id": server_id},
            timeout=60,
        )
        resp.raise_for_status()
        body = resp.json()
    except requests.RequestException as exc:
        return {
            "ip_list": [],
            "ip_policy": "",
            "error": str(exc),
            "raw": None,
        }

    data = body.get("data", body)
    if not isinstance(data, dict):
        data = {}

    ip_list = parse_ip_list(data.get("ip_list"))
    policy = str(data.get("ip_policy") or data.get("ipPolicy") or "").strip().lower()

    return {
        "ip_list": ip_list,
        "ip_policy": policy,
        "error": None,
        "raw": body,
    }


def ip_is_whitelisted(target: str, wl: dict[str, Any]) -> bool:
    policy = wl.get("ip_policy") or ""
    if policy == "allow_all":
        return True

    normalized_targets = {target}
    try:
        normalized_targets.add(str(ipaddress.ip_address(target)))
    except ValueError:
        pass

    listed = {normalize_whitelist_entry(x) for x in wl.get("ip_list", [])}
    return bool(normalized_targets & listed)


def validate_ipv4(ip: str) -> str:
    ip = ip.strip()
    if not ip:
        raise ValueError("empty")
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError as exc:
        raise ValueError(f"not a valid IP: {ip}") from exc
    if addr.version != 4:
        raise ValueError(f"only IPv4 supported for now: {ip}")
    return str(addr)


def load_ips_from_file(path: str) -> list[str]:
    ips: list[str] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            for part in line.replace(",", " ").split():
                ips.append(part)
    return ips


def prompt_ips() -> list[str]:
    print(
        "Enter IPs to check (one per line). "
        "Press Enter on an empty line when done."
    )
    print(f"Tip: paste your list, then Enter on a blank line. Defaults if empty:")
    for ip in DEFAULT_CHECK_IPS:
        print(f"  {ip}")
    lines: list[str] = []
    while True:
        try:
            line = input("> ").strip()
        except EOFError:
            break
        if not line:
            break
        lines.append(line)
    if not lines:
        return list(DEFAULT_CHECK_IPS)
    ips: list[str] = []
    for line in lines:
        for part in line.replace(",", " ").split():
            ips.append(part)
    return ips


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check SSH/SFTP whitelist for IPs across Cloudways servers.",
    )
    parser.add_argument(
        "--ips",
        help="Comma- or space-separated IPv4 addresses to check",
    )
    parser.add_argument(
        "--ips-file",
        metavar="PATH",
        help="File with one IP per line (# comments allowed)",
    )
    parser.add_argument(
        "--server-id",
        action="append",
        dest="server_ids",
        metavar="ID",
        help="Limit to specific server ID(s); repeatable",
    )
    parser.add_argument(
        "--use-default-ips",
        action="store_true",
        help=f"Use built-in IP list ({len(DEFAULT_CHECK_IPS)} addresses) without prompting",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON summary to stdout",
    )
    parser.add_argument(
        "--fail-on-missing",
        action="store_true",
        help="Exit code 1 if any IP is missing on any server",
    )
    return parser.parse_args()


def resolve_credentials() -> tuple[str, str]:
    email = os.environ.get("CLOUDWAYS_EMAIL", "").strip()
    api_key = os.environ.get("CLOUDWAYS_API_KEY", "").strip()
    if not email:
        email = input("Cloudways email: ").strip()
    if not api_key:
        api_key = getpass.getpass("Cloudways API key: ").strip()
    if not email or not api_key:
        print("[ERROR] Email and API key are required.")
        sys.exit(1)
    return email, api_key


def collect_ips(args: argparse.Namespace) -> list[str]:
    raw: list[str] = []
    if args.ips_file:
        raw.extend(load_ips_from_file(args.ips_file))
    if args.ips:
        for part in args.ips.replace(",", " ").split():
            raw.append(part)
    if not raw and args.use_default_ips:
        raw = list(DEFAULT_CHECK_IPS)
    if not raw:
        raw = prompt_ips()

    seen: set[str] = set()
    ordered: list[str] = []
    for item in raw:
        ip = validate_ipv4(item)
        if ip not in seen:
            seen.add(ip)
            ordered.append(ip)
    return ordered


def server_label(server: dict[str, Any]) -> str:
    return str(server.get("label") or server.get("name") or server.get("id") or "?")


def server_public_ip(server: dict[str, Any]) -> str:
    return str(
        server.get("public_ip")
        or server.get("server_ip")
        or server.get("ip")
        or ""
    )


def main() -> None:
    args = parse_args()
    check_ips = collect_ips(args)
    email, api_key = resolve_credentials()
    token = fetch_token(email, api_key)

    servers = fetch_servers(token)
    if args.server_ids:
        want = {str(x) for x in args.server_ids}
        servers = [s for s in servers if str(s.get("id")) in want]
        if not servers:
            print(f"[ERROR] No servers matched --server-id {sorted(want)}")
            sys.exit(1)

    servers.sort(key=lambda s: str(s.get("id", "")))

    print(f"\nChecking {len(check_ips)} IP(s) on {len(servers)} server(s) ...\n")

    results: list[dict[str, Any]] = []
    any_missing = False

    for server in servers:
        sid = str(server.get("id"))
        wl = fetch_ssh_whitelist(sid, token)
        time.sleep(RATE_SLEEP)

        row: dict[str, Any] = {
            "server_id": sid,
            "label": server_label(server),
            "public_ip": server_public_ip(server),
            "ip_policy": wl.get("ip_policy") or "(unknown)",
            "whitelist_ips": wl.get("ip_list", []),
            "ips": {},
            "error": wl.get("error"),
        }

        if wl.get("error"):
            print(f"Server {sid} ({server_label(server)}): API error — {wl['error']}")
            any_missing = True
            for ip in check_ips:
                row["ips"][ip] = "error"
            results.append(row)
            continue

        policy = wl.get("ip_policy") or ""
        listed = wl.get("ip_list", [])
        print(
            f"Server {sid} — {server_label(server)} "
            f"({server_public_ip(server) or 'no public IP in API'})"
        )
        print(f"  SSH/SFTP policy: {policy or '(not returned)'}")
        print(f"  Whitelisted entries ({len(listed)}): {', '.join(listed) if listed else '(none)'}")

        for ip in check_ips:
            ok = ip_is_whitelisted(ip, wl)
            status = "OK" if ok else "MISSING"
            if not ok:
                any_missing = True
            row["ips"][ip] = status
            print(f"    {ip}: {status}")

        print()
        results.append(row)

    if args.json:
        import json

        print(json.dumps({"check_ips": check_ips, "servers": results}, indent=2))

    missing_summary: dict[str, list[str]] = {}
    for row in results:
        sid = row["server_id"]
        for ip, status in row["ips"].items():
            if status != "OK":
                missing_summary.setdefault(ip, []).append(sid)

    if missing_summary:
        print("Summary — not whitelisted (or API error) on:")
        for ip, sids in sorted(missing_summary.items()):
            print(f"  {ip}: server id(s) {', '.join(sids)}")
    else:
        print("Summary — all checked IPs are whitelisted on every server.")

    if args.fail_on_missing and any_missing:
        sys.exit(1)


if __name__ == "__main__":
    main()
