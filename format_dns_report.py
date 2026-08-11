#!/usr/bin/env python3
"""Format dns_audit TSV/space-separated export into readable TXT grouped by domain."""
import re
import sys
from collections import defaultdict
from pathlib import Path

LINE_RE = re.compile(
    r"^(\S+)\s+(@|\S+)\s+(A|AAAA|MX|NS|SOA|TXT|CNAME|SRV|SUBDOMAIN)\s+(.+?)\s{2,}(dig|securitytrails)\s*$",
    re.I,
)

EMAIL_HOSTS = {
    "mail", "smtp", "pop", "pop3", "imap", "webmail",
    "autodiscover", "autoconfig", "_dmarc",
}


def fqdn(apex: str, host: str) -> str:
    if host == "@":
        return apex
    if host.startswith("_"):
        return f"{host}.{apex}"
    return f"{host}.{apex}"


def parse_file(path: Path) -> tuple[dict, int]:
    rows_by_domain: dict[str, list] = defaultdict(list)
    skipped = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("apex_domain"):
            continue
        m = LINE_RE.match(line)
        if not m:
            skipped += 1
            continue
        apex, host, rtype, value, source = m.groups()
        rows_by_domain[apex].append({
            "host": host,
            "type": rtype.upper(),
            "value": value.strip(),
            "source": source.lower(),
        })
    return rows_by_domain, skipped


def format_report(rows_by_domain: dict, skipped: int) -> str:
    out: list[str] = [
        "DNS AUDIT REPORT — CLOUDWAYS ACCOUNT",
        "Source: dns_report export (dig + SecurityTrails where available)",
        f"Domains: {len(rows_by_domain)}",
        f"Records: {sum(len(v) for v in rows_by_domain.values())}",
        f"Parse skipped lines: {skipped}",
        "",
    ]

    for apex in sorted(rows_by_domain):
        recs = rows_by_domain[apex]
        email = [r for r in recs if r["type"] in {"MX", "TXT"} or r["host"] in EMAIL_HOSTS]
        infra = [r for r in recs if r["type"] in {"NS", "SOA"}]
        other = [r for r in recs if r not in email and r not in infra]

        out += ["=" * 80, f"DOMAIN: {apex}", "=" * 80]

        def append_block(title: str, items: list) -> None:
            if not items:
                return
            out.append("")
            out.append(title)
            out.append("-" * len(title))
            for r in sorted(items, key=lambda x: (x["type"], x["host"], x["value"])):
                name = fqdn(apex, r["host"])
                out.append(f"  {r['type']:<6} {name:<48} {r['value']}  ({r['source']})")

        append_block("DNS INFRASTRUCTURE (NS / SOA)", infra)
        append_block("EMAIL-RELATED RECORDS", email)
        append_block("WEB / OTHER RECORDS", other)
        out.append("")

    return "\n".join(out)


def main() -> None:
    inp = Path(sys.argv[1] if len(sys.argv) > 1 else "dns_report.tsv")
    dest = Path(sys.argv[2] if len(sys.argv) > 2 else "dns_report_formatted.txt")
    rows, skipped = parse_file(inp)
    dest.write_text(format_report(rows, skipped), encoding="utf-8")
    print(f"Wrote {dest} — {len(rows)} domains, {skipped} lines skipped")


if __name__ == "__main__":
    main()
