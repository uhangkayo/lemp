#!/usr/bin/env bash

set -Eeuo pipefail

# Colours
red=$'\e[1;31m'
grn=$'\e[1;32m'
yel=$'\e[1;33m'
blu=$'\e[1;34m'
cyn=$'\e[1;36m'
end=$'\e[0m'

# Ensure running as root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "${red}Please run this script as root${end}"
  exit 1
fi

info() { echo "[INFO] $*"; }
ok() { echo "${grn}[OK]${end} $*"; }
warn() { echo "${yel}[WARN]${end} $*"; }
err() { echo "${red}[ERROR]${end} $*"; }

command -v ip >/dev/null 2>&1 || { err "'ip' command not found"; exit 1; }

has_global_ipv6() {
  # Returns 0 if any publicly routable IPv6 address is present on any interface
  # Excludes link-local (fe80::/10) and unique local addresses (fc00::/7).
  mapfile -t addresses < <(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}')
  if ((${#addresses[@]} == 0)); then
    return 1
  fi

  local addr lowered found_ula=0
  for addr in "${addresses[@]}"; do
    lowered="${addr%%/*}"
    lowered="${lowered,,}"
    [[ -z "$lowered" ]] && continue
    if [[ "$lowered" == fe80* ]]; then
      continue
    fi
    if [[ "$lowered" == fc* || "$lowered" == fd* ]]; then
      found_ula=1
      continue
    fi
    return 0
  done

  if ((found_ula)); then
    warn "Only unique local IPv6 addresses (fc00::/7) detected; public IPv6 is not configured."
  fi
  return 1
}

nginx_installed() { command -v nginx >/dev/null 2>&1; }

nginx_has_ipv6_listen() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # Check specific file for any IPv6 listen directive
  grep -qE "^\s*listen\s*\[::\]" "$f"
}

# -----------------------------
# UFW (Firewall) helpers
# -----------------------------
ufw_installed() { command -v ufw >/dev/null 2>&1; }

ufw_active() {
  # Returns 0 if UFW Status: active
  ufw status 2>/dev/null | grep -q "Status: active"
}

ensure_ufw_ipv6_enabled() {
  local conf="/etc/ufw/ufw.conf"
  if [[ ! -f "$conf" ]]; then
    warn "UFW config not found: $conf"
    return 0
  fi
  if grep -q '^IPV6=yes' "$conf"; then
    ok "UFW IPV6 already enabled in $conf"
  else
    if grep -q '^IPV6=' "$conf"; then
      sed -i 's/^IPV6=.*/IPV6=yes/' "$conf"
    else
      echo 'IPV6=yes' >>"$conf"
    fi
    ok "Enabled IPv6 in UFW config"
    # Reload UFW to apply config; if reload fails, toggle enable
    if ! ufw reload >/dev/null 2>&1; then
      yes | ufw disable >/dev/null 2>&1 || true
      yes | ufw enable >/dev/null 2>&1 || true
    fi
  fi
}

ensure_ufw_http_https_allowed() {
  # Allow 80/tcp and 443/tcp if not already present
  if ! ufw status | grep -qE '^80/tcp\s+ALLOW'; then
    ufw allow 80/tcp >/dev/null 2>&1 || warn "Failed to allow 80/tcp"
  fi
  if ! ufw status | grep -qE '^443/tcp\s+ALLOW'; then
    ufw allow 443/tcp >/dev/null 2>&1 || warn "Failed to allow 443/tcp"
  fi
  ok "Verified UFW allows HTTP/HTTPS (applies to IPv4 & IPv6 when IPV6=yes)"
}

ensure_ipv6_listen_in_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  local python_bin=""
  if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    python_bin="python"
  else
    warn "Python is required to adjust IPv6 listeners in $f but was not found."
    return 1
  fi

  "$python_bin" - "$f" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
lines = text.splitlines()


def ensure_port(port, current_lines):
    ipv4_pattern = re.compile(r'^(\s*)listen\s+(?:[0-9.*:]*:)?' + port + r'\b([^;]*);', re.IGNORECASE)
    ipv6_pattern = re.compile(r'^\s*listen\s*\[::\]\s*:' + port + r'\b', re.IGNORECASE)
    new_lines = []
    changed = False
    depth = 0

    for idx, line in enumerate(current_lines):
        line_depth = depth
        new_lines.append(line)
        match = ipv4_pattern.match(line)
        if match:
            indent, extras = match.groups()
            extras = extras.strip()
            has_ipv6 = False
            temp_depth = line_depth
            j = idx + 1
            while j < len(current_lines):
                next_line = current_lines[j]
                next_depth = temp_depth
                if next_depth < line_depth:
                    break
                if ipv6_pattern.match(next_line) and next_depth == line_depth:
                    has_ipv6 = True
                    break
                temp_depth += next_line.count('{') - next_line.count('}')
                j += 1
            if not has_ipv6:
                new_line = f"{indent}listen [::]:{port}"
                if extras:
                    new_line += f" {extras}"
                new_line += ";"
                new_lines.append(new_line)
                changed = True
        depth += line.count('{') - line.count('}')

    return new_lines, changed


lines, changed80 = ensure_port('80', lines)
lines, changed443 = ensure_port('443', lines)

if changed80 or changed443:
    ending = '\n' if text.endswith('\n') else ''
    Path(sys.argv[1]).write_text('\n'.join(lines) + ending)
PY
}

# List all site config files in /etc/nginx/sites-available
list_sites_available() {
  shopt -s nullglob
  local files=(/etc/nginx/sites-available/*)
  # Print one per line for easy capture
  for f in "${files[@]}"; do
    [[ -f "$f" || -L "$f" ]] && printf "%s\n" "$f"
  done
}

# Resolve a user-provided site name to a full path under sites-available
resolve_site_path() {
  local name="$1"
  # If absolute or relative path provided, use as-is when it exists
  if [[ -e "$name" ]]; then
    printf "%s" "$name"
    return 0
  fi
  # Otherwise treat as a filename inside sites-available
  local candidate="/etc/nginx/sites-available/$name"
  if [[ -e "$candidate" ]]; then
    printf "%s" "$candidate"
    return 0
  fi
  return 1
}

configure_nginx_ipv6() {
  if ! nginx_installed; then
    err "Nginx is not installed or not in PATH"
    return 1
  fi

  info "Configuring Nginx to listen on IPv6..."

  # Update Lempzy vhost templates for future sites
  local templates=(
    "/root/Lempzy/scripts/vhost-nocache"
    "/root/Lempzy/scripts/vhost-fastcgi"
    "/root/Lempzy/scripts/vhost-nocache-invoiceninja"
  )
  for t in "${templates[@]}"; do
    if [[ -f "$t" ]]; then
      ensure_ipv6_listen_in_file "$t"
      ok "Updated template: $t"
    else
      warn "Template not found: $t"
    fi
  done

  # Check all sites in sites-available and configure those without IPv6
  local sites_list
  mapfile -t sites_list < <(list_sites_available)
  if ((${#sites_list[@]} == 0)); then
    warn "No site configs found under /etc/nginx/sites-available"
  else
    local sites_updated=0
    info "Checking all site configs for IPv6 listen directives..."
    for f in "${sites_list[@]}"; do
      if nginx_has_ipv6_listen "$f"; then
        ok "IPv6 already configured in: $(basename "$f")"
      else
        ensure_ipv6_listen_in_file "$f"
        ok "Added IPv6 listeners to: $(basename "$f")"
        ((sites_updated++))
      fi
    done
    if ((sites_updated == 0)); then
      ok "All sites already have IPv6 configured"
    else
      ok "Updated $sites_updated site(s) with IPv6 listeners"
    fi
  fi

  if nginx -t; then
    local reload_ok=0
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl reload nginx >/dev/null 2>&1; then
        reload_ok=1
      else
        warn "systemctl reload nginx failed; attempting fallback methods..."
      fi
    else
      info "systemctl not available; attempting alternative reload methods..."
    fi

    if ((reload_ok == 0)) && command -v service >/dev/null 2>&1; then
      if service nginx reload >/dev/null 2>&1; then
        reload_ok=1
      fi
    fi

    if ((reload_ok == 0)) && command -v nginx >/dev/null 2>&1; then
      if nginx -s reload >/dev/null 2>&1; then
        reload_ok=1
      fi
    fi

    if ((reload_ok)); then
      ok "Nginx reloaded with IPv6 listeners"
    else
      warn "Failed to reload Nginx automatically. Please reload Nginx manually."
      return 1
    fi
  else
    err "nginx -t failed; please review your configs"
    return 1
  fi
}

test_ipv6_single_site() {
  local sites_list
  mapfile -t sites_list < <(list_sites_available)
  if ((${#sites_list[@]} == 0)); then
    warn "No site configs found under /etc/nginx/sites-available"
    return 1
  fi
  echo ""
  echo "Available sites:"
  for s in "${sites_list[@]}"; do
    echo " - $(basename "$s")"
  done
  echo ""
  read -r -p "${cyn}Enter site name or full path to test: ${end}" site_name
  if [[ -z "$site_name" ]]; then
    warn "No site name provided"
    return 1
  fi
  local target
  if target=$(resolve_site_path "$site_name"); then
    if nginx_has_ipv6_listen "$target"; then
      ok "IPv6 listen directives found in: $(basename "$target")"
    else
      warn "No IPv6 listen directives found in: $(basename "$target")"
    fi
  else
    err "Site not found: $site_name"
    return 1
  fi
}

test_ipv6_all_sites() {
  local sites_list
  mapfile -t sites_list < <(list_sites_available)
  if ((${#sites_list[@]} == 0)); then
    warn "No site configs found under /etc/nginx/sites-available"
    return 1
  fi
  echo ""
  info "Checking IPv6 configuration for all sites..."
  local all_configured=1
  for f in "${sites_list[@]}"; do
    if nginx_has_ipv6_listen "$f"; then
      ok "IPv6 configured in: $(basename "$f")"
    else
      warn "No IPv6 listen directives in: $(basename "$f")"
      all_configured=0
    fi
  done
  if [[ $all_configured -eq 1 ]]; then
    ok "All sites have IPv6 configured"
  else
    warn "Some sites are missing IPv6 configuration"
  fi
}

show_menu() {
  clear
  echo "########################### SERVER CONFIGURED BY MIGUEL EMMARA ###########################"
  echo "                                   ${grn}IPv6 CONFIGURATION${end}"
  echo ""
  echo "${cyn}Reminder:${end} If you use Cloudflare (DNS-only), add an AAAA record pointing to your server’s global IPv6 address."
  echo "Without an AAAA record, IPv6 clients will not reach your site via IPv6."
  echo ""
  echo "Please choose an option:"
  echo "  1) Configure IPv6 for all sites"
  echo "  2) Test IPv6 configuration for a single site"
  echo "  3) Test IPv6 configuration for all sites"
  echo "  4) Exit"
  echo ""
  read -r -p "${cyn}Enter your choice [1-4]: ${end}" choice
}

main() {
  if ! has_global_ipv6; then
    warn "No global IPv6 address detected on this server."
    echo "${yel}Action required:${end} Obtain an IPv6 address/prefix from your cloud provider and configure it on the server (Netplan/ifupdown)."
    echo "Once IPv6 is configured, re-run this menu to set up Nginx."
    echo "If you use Cloudflare (DNS-only), don’t forget to add an AAAA record with your server’s IPv6 address."
    return 0
  fi

  ok "Global IPv6 detected."

  while true; do
    show_menu
    case "$choice" in
      1)
        configure_nginx_ipv6 || return 1
        # Check UFW after configuration
        if ufw_installed; then
          if ufw_active; then
            info "UFW is active; verifying IPv6 and web ports..."
            ensure_ufw_ipv6_enabled
            ensure_ufw_http_https_allowed
          else
            warn "UFW installed but not active; skipping firewall changes"
          fi
        else
          warn "UFW not installed; skipping firewall checks"
        fi
        echo ""
        echo "${grn}IPv6 configuration completed.${end}"
        ;;
      2)
        test_ipv6_single_site
        ;;
      3)
        test_ipv6_all_sites
        ;;
      4)
        echo "${grn}Exiting.${end}"
        break
        ;;
      *)
        warn "Invalid choice. Please select 1, 2, 3, or 4."
        ;;
    esac
    echo ""
    read -r -p "${cyn}Press Enter to return to the menu...${end}"
  done
  return 0
}

main

echo ""
echo "${grn}IPv6 check and configuration completed.${end}"
echo ""
echo "${cyn}Reminder:${end} If you use Cloudflare (DNS-only), add an AAAA record with your server’s global IPv6 address."
echo "Update DNS so IPv6 resolves correctly for your domain."
