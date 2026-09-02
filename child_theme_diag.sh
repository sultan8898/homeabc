#!/bin/bash
# WordPress child theme activation diagnostics (Cloudways / WP-CLI).
#
# Typical failures: wrong Template: header, case mismatch, missing style.css,
# parent theme not installed, minified style.css header on one line, nested
# theme roots (e.g. sage/resources), or PHP fatals in functions.php.
#
# Usage:
#   ./child_theme_diag.sh <app_slug> [child_theme_folder]
#   ./child_theme_diag.sh /home/master/applications/APP/public_html [child_theme_folder]
#
# Run from the app directory (public_html parent):
#   cd /home/master/applications/APP && ./child_theme_diag.sh . my-child-theme
#
# Ephemeral (after merge):
#   curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/main/child_theme_diag.sh | bash -s -- APP_SLUG child-folder

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

warn() { echo -e "${YELLOW}WARN${NC}: $*"; }
fail() { echo -e "${RED}FAIL${NC}: $*"; }
ok()   { echo -e "${GREEN}OK${NC}:   $*"; }
info() { echo -e "${CYAN}--->${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 <app_slug|wp_root_path> [child_theme_folder]

If child_theme_folder is omitted, all installed child themes are checked.

Examples:
  $0 afurtxebjn
  $0 afurtxebjn my-child-theme
  $0 /home/master/applications/afurtxebjn/public_html storefront-child
EOF
}

ctd_resolve_wp_root() {
    local arg="${1:-}"
    if [[ -z "$arg" ]]; then
        usage >&2
        return 1
    fi

    if [[ -f "$arg/wp-config.php" ]]; then
        WP_ROOT=$(cd "$arg" && pwd)
        return 0
    fi

    if [[ -f "$arg/public_html/wp-config.php" ]]; then
        WP_ROOT=$(cd "$arg/public_html" && pwd)
        return 0
    fi

    local apps_base="/home/master/applications"
    if [[ ! -d "$apps_base" ]]; then
        local hid
        hid=$(hostname 2>/dev/null | grep -oE '^[0-9]+' || true)
        if [[ -n "$hid" && -d "/home/${hid}.cloudwaysapps.com" ]]; then
            apps_base="/home/${hid}.cloudwaysapps.com"
        fi
    fi

    if [[ -d "$apps_base/$arg" ]]; then
        local found
        found=$(find "$apps_base/$arg/public_html" -maxdepth 4 -name wp-config.php 2>/dev/null \
            | awk '{print gsub(/\//,"/"), $0}' | sort -n | head -1 | cut -d' ' -f2-)
        if [[ -n "$found" ]]; then
            WP_ROOT=$(dirname "$found")
            return 0
        fi
    fi

    fail "Could not resolve WordPress root from '$arg'"
    return 1
}

ctd_wp() {
    local site_url="${WP_SITE_URL:-}"
    if [[ -n "$site_url" ]]; then
        (cd "$WP_ROOT" && wp "$@" --allow-root --url="$site_url" 2>&1)
    else
        (cd "$WP_ROOT" && wp "$@" --allow-root 2>&1)
    fi
}

ctd_parse_style_header() {
    local css="$1"
    local key="$2"
    awk -v k="$key" '
        BEGIN { IGNORECASE=0 }
        /^\/\*/ { inhdr=1; line=$0; next }
        inhdr {
            line = line " " $0
            if ($0 ~ /\*\//) {
                inhdr=0
                if (match(line, k ":[ \t]*([^ \r\n*]+)", a)) {
                    gsub(/\r$/, "", a[1])
                    print a[1]
                }
                exit
            }
            next
        }
        inhdr==0 && NR<=30 && $0 ~ k":" {
            sub(/^[^:]*:[ \t]*/, "", $0)
            gsub(/\r$/, "", $0)
            print $0
            exit
        }
    ' "$css" 2>/dev/null
}

ctd_theme_is_child() {
    local theme_dir="$1"
    local css="$theme_dir/style.css"
    [[ -f "$css" ]] || return 1
    local template
    template=$(ctd_parse_style_header "$css" "Template")
    [[ -n "$template" ]]
}

ctd_check_one_theme() {
    local slug="$1"
    local themes_root="$WP_ROOT/wp-content/themes"
    local theme_dir="$themes_root/$slug"
    local issues=0

    echo ""
    echo "=========================================================="
    info "Theme: $slug"
    echo "=========================================================="

    if [[ ! -d "$theme_dir" ]]; then
        fail "Directory missing: $theme_dir"
        return 1
    fi

    local css="$theme_dir/style.css"
    if [[ ! -f "$css" ]]; then
        fail "style.css missing (WP-CLI often reports 'Stylesheet is missing')"
        # Nested roots (Sage, etc.)
        local nested
        nested=$(find "$theme_dir" -maxdepth 3 -name style.css 2>/dev/null | head -n 5)
        if [[ -n "$nested" ]]; then
            warn "Found style.css under subdirectories — try activating with the path WP-CLI expects:"
            echo "$nested" | while read -r p; do
                local rel="${p#"$themes_root"/}"
                rel="${rel%/style.css}"
                echo "       wp theme activate $rel"
            done
        fi
        issues=$((issues + 1))
    else
        ok "style.css present ($(wc -c <"$css" | tr -d ' ') bytes)"

        if [[ ! -r "$css" ]]; then
            fail "style.css not readable (check owner/perms for web + CLI user)"
            issues=$((issues + 1))
        fi

        local hdr_lines
        hdr_lines=$(awk '/^\/\*/{f=1} f{print} /\*\//{exit}' "$css" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$hdr_lines" -le 1 ]] && grep -q 'Template:' "$css"; then
            warn "Theme header may be minified (single line). WordPress can miss Template: — restore line breaks in the /* ... */ block."
            issues=$((issues + 1))
        fi

        local theme_name template
        theme_name=$(ctd_parse_style_header "$css" "Theme Name")
        template=$(ctd_parse_style_header "$css" "Template")

        echo "       Theme Name: ${theme_name:-<not set>}"
        echo "       Template:   ${template:-<not set>}"

        if [[ -z "$template" ]]; then
            info "Not a child theme (no Template: line) — skipping parent checks."
            return 0
        fi

        local parent_dir="$themes_root/$template"
        if [[ ! -d "$parent_dir" ]]; then
            fail "Parent folder '$template' not found under wp-content/themes/"
            info "Installed theme folders:"
            ls -1 "$themes_root" 2>/dev/null | sed 's/^/         /'
            issues=$((issues + 1))
        else
            ok "Parent directory exists: $template"
            if [[ ! -f "$parent_dir/style.css" ]]; then
                warn "Parent style.css missing — parent may be incomplete."
                issues=$((issues + 1))
            fi
        fi

        # Case-sensitive folder match (Linux)
        if [[ -d "$themes_root" ]]; then
            local exact
            exact=$(ls -1 "$themes_root" 2>/dev/null | grep -x "$template" || true)
            if [[ -z "$exact" && -d "$parent_dir" ]]; then
                local closest
                closest=$(ls -1 "$themes_root" 2>/dev/null | grep -i "^${template}$" || true)
                if [[ -n "$closest" && "$closest" != "$template" ]]; then
                    warn "Template '$template' does not match folder case. On Linux use: Template: $closest"
                    issues=$((issues + 1))
                fi
            fi
        fi
    fi

    if [[ -f "$theme_dir/functions.php" ]]; then
        if php -l "$theme_dir/functions.php" >/dev/null 2>&1; then
            ok "functions.php syntax (php -l)"
        else
            fail "functions.php has a syntax error (can white-screen on activation):"
            php -l "$theme_dir/functions.php" 2>&1 | sed 's/^/         /'
            issues=$((issues + 1))
        fi
    fi

    if command -v wp >/dev/null 2>&1; then
        local status
        status=$(ctd_wp theme get "$slug" --field=status 2>/dev/null | tail -n 1 || true)
        if [[ -n "$status" ]]; then
            echo "       WP-CLI status: $status"
        fi

        if ctd_wp theme list --format=csv 2>/dev/null | grep -q "^$slug,"; then
            ok "WP-CLI lists theme '$slug'"
        else
            warn "WP-CLI theme list does not include '$slug' (path/permissions or broken stylesheet)"
            issues=$((issues + 1))
        fi

        if [[ "$status" != "active" ]]; then
            info "Testing wp theme activate (reverts to previous theme afterward):"
            local act_out prev_active
            prev_active=$(ctd_wp option get stylesheet 2>/dev/null | tail -n 1 || true)
            act_out=$(ctd_wp theme activate "$slug" 2>&1) || true
            if echo "$act_out" | grep -qiE 'success|already'; then
                ok "wp theme activate succeeded"
                if [[ -n "$prev_active" && "$prev_active" != "$slug" ]]; then
                    ctd_wp theme activate "$prev_active" >/dev/null 2>&1 || \
                        warn "Reverted activation test failed — confirm active theme in WP admin"
                fi
            else
                fail "wp theme activate failed:"
                echo "$act_out" | sed 's/^/         /'
                issues=$((issues + 1))
            fi
        fi
    else
        warn "wp not on PATH — install WP-CLI or run as application user with wp in PATH"
    fi

    if [[ "$issues" -gt 0 ]]; then
        echo ""
        info "Suggested fixes:"
        echo "  • Set Template: in child style.css to the parent folder name exactly (case-sensitive)."
        echo "  • Ensure parent theme is installed and child style.css header is not minified to one line."
        echo "  • For nested theme roots, activate the subdirectory WP-CLI recognizes (see warnings above)."
        echo "  • Fix functions.php syntax errors before activating."
        return 1
    fi
    ok "No obvious blockers for '$slug'"
    return 0
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
        usage
        exit 0
    fi

    local target="$1"
    local child_filter="${2:-}"

    ctd_resolve_wp_root "$target" || exit 1
    WP_SITE_URL=""
    if command -v wp >/dev/null 2>&1; then
        WP_SITE_URL=$(ctd_wp option get siteurl 2>/dev/null | tail -n 1 || true)
    fi

    echo "=========================================================="
    echo " CHILD THEME DIAG  $(date)"
    echo " WP root: $WP_ROOT"
    [[ -n "$WP_SITE_URL" ]] && echo " Site URL: $WP_SITE_URL"
    echo "=========================================================="

    local themes_root="$WP_ROOT/wp-content/themes"
    if [[ ! -d "$themes_root" ]]; then
        fail "No themes directory: $themes_root"
        exit 1
    fi

    local active_stylesheet active_template
    if command -v wp >/dev/null 2>&1; then
        active_stylesheet=$(ctd_wp option get stylesheet 2>/dev/null | tail -n 1 || true)
        active_template=$(ctd_wp option get template 2>/dev/null | tail -n 1 || true)
        info "Active stylesheet (child): ${active_stylesheet:-unknown}"
        info "Active template (parent):    ${active_template:-unknown}"
    fi

    local failed=0
    if [[ -n "$child_filter" ]]; then
        ctd_check_one_theme "$child_filter" || failed=1
    else
        local d slug
        for d in "$themes_root"/*; do
            [[ -d "$d" ]] || continue
            slug=$(basename "$d")
            if ctd_theme_is_child "$d"; then
                ctd_check_one_theme "$slug" || failed=1
            fi
        done
        if [[ "$failed" -eq 0 ]]; then
            local any_child=0
            for d in "$themes_root"/*; do
                [[ -d "$d" ]] || continue
                if ctd_theme_is_child "$d"; then any_child=1; break; fi
            done
            if [[ "$any_child" -eq 0 ]]; then
                warn "No child themes detected (no Template: in any style.css). Listing all themes:"
                if command -v wp >/dev/null 2>&1; then
                    ctd_wp theme list 2>/dev/null || ls -1 "$themes_root"
                else
                    ls -1 "$themes_root"
                fi
            fi
        fi
    fi

    exit "$failed"
}

main "$@"
