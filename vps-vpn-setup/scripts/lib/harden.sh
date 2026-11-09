#!/usr/bin/env bash
# vpnctl harden: open the VPN ports and harden SSH without locking yourself out.
#
# Sourced by scripts/vpnctl — do not execute directly.
#
# Safety model:
#   * ports are opened BEFORE any sshd change is applied;
#   * sshd config is validated with `sshd -t` and `sshd -T` before restart;
#   * a port change schedules an automatic rollback in 5 minutes
#     (systemd-run transient timer); `vpnctl harden --confirm` cancels it;
#   * password auth is only disabled when an authorized_keys file exists.

HARDEN_SSH_PORT=""
HARDEN_LOCKDOWN=0
HARDEN_SKIP_SSH=0
HARDEN_CONFIRM=0
HARDEN_FORCE_PASSWORD_OFF=0
HARDEN_UNIT="vpnctl-ssh-rollback"

harden_help() {
  cat <<'EOF'
harden options:
  --ssh-port N        move sshd to port N (opens the port first, auto-rollback in 5 min)
  --confirm           cancel a pending rollback (run after verifying SSH still works)
  --lockdown          default-deny inbound (allows SSH + installed VPN ports only)
  --no-ssh            only touch the firewall; never modify sshd
  --force-password-off  disable password auth even without authorized_keys (dangerous)
  --status            show current SSH/firewall state and exit
EOF
}

cmd_harden() {
  while [ "$#" -gt 0 ]; do
    case $1 in
      --ssh-port) HARDEN_SSH_PORT="${2:-}"; shift 2 ;;
      --lockdown) HARDEN_LOCKDOWN=1; shift ;;
      --no-ssh) HARDEN_SKIP_SSH=1; shift ;;
      --confirm) HARDEN_CONFIRM=1; shift ;;
      --force-password-off) HARDEN_FORCE_PASSWORD_OFF=1; shift ;;
      --status) harden_status; return 0 ;;
      -h|--help) harden_help; return 0 ;;
      *) die "harden: unknown option '$1'" ;;
    esac
  done

  if [ "$HARDEN_CONFIRM" = "1" ]; then
    harden_cancel_rollback
    return 0
  fi
  require_linux
  if [ "$DRY_RUN" != "1" ]; then require_root harden; fi
  detect_os

  log_step "firewall"
  local kind; kind="$(firewall_kind)"
  log_info "detected firewall: $kind"
  harden_open_vpn_ports
  if [ -n "$HARDEN_SSH_PORT" ]; then
    validate_port_number "$HARDEN_SSH_PORT"
    open_port "$HARDEN_SSH_PORT" tcp
  fi
  if [ "$HARDEN_LOCKDOWN" = "1" ]; then
    harden_lockdown "$kind"
  elif [ "$kind" = "none" ]; then
    log_warn "no host firewall detected — make sure your provider's security group allows the VPN ports"
    log_warn "cloud VPS: open $(harden_port_list) in the console too"
  fi

  if [ "$HARDEN_SKIP_SSH" = "1" ]; then
    log_info "--no-ssh: sshd left untouched"
    return 0
  fi

  log_step "ssh"
  harden_ssh

  log_step "summary"
  harden_status
}

# --- firewall --------------------------------------------------------------

firewall_kind() {
  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then printf 'ufw'; return 0; fi
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then printf 'firewalld'; return 0; fi
  if have nft && nft list ruleset 2>/dev/null | grep -q 'hook input'; then printf 'nftables'; return 0; fi
  if have iptables; then printf 'iptables'; return 0; fi
  printf 'none'
}

# All ports that installed backends need.
harden_port_list() {
  local be port proto out=""
  for be in wireguard xray-reality ss2022 hysteria2 trojan; do
    be_installed "$be" || continue
    port="$(meta_get "$be" PORT)"
    proto="$(meta_get "$be" PROTO)"
    [ -n "$port" ] || continue
    case $be in
      ss2022) proto="tcp,udp" ;;
      wireguard|hysteria2) proto="udp" ;;
      xray-reality|trojan) proto="tcp" ;;
    esac
    out="$out $port/$proto"
  done
  if [ -r /etc/vpnctl/sub/meta.env ]; then
    local sp; sp="$(sed -n 's/^PORT=//p' /etc/vpnctl/sub/meta.env | head -n 1)"
    if [ -n "$sp" ]; then out="$out $sp/tcp"; fi
  fi
  printf '%s' "${out# }"
}

open_port() {
  local port="$1" protos="$2" kind p
  kind="$(firewall_kind)"
  case $kind in
    ufw)
      for p in $(printf '%s' "$protos" | tr ',' ' '); do
        if ufw status 2>/dev/null | grep -qE "^${port}/${p}[[:space:]]+ALLOW"; then
          log_debug "ufw: $port/$p already allowed"
        else
          run ufw allow "$port/$p" >/dev/null
          log_ok "ufw: allowed $port/$p"
        fi
      done
      ;;
    firewalld)
      for p in $(printf '%s' "$protos" | tr ',' ' '); do
        run firewall-cmd --permanent --add-port="$port/$p" >/dev/null
        log_ok "firewalld: allowed $port/$p"
      done
      run firewall-cmd --reload >/dev/null
      ;;
    nftables)
      for p in $(printf '%s' "$protos" | tr ',' ' '); do
        if nft list ruleset 2>/dev/null | grep -q "$p dport $port accept"; then
          log_debug "nftables: $port/$p already allowed"
        else
          run nft insert rule inet filter input "$p" dport "$port" accept 2>/dev/null \
            || log_warn "nftables: could not insert a rule for $port/$p; add it to /etc/nftables.conf manually"
          log_ok "nftables: allowed $port/$p (runtime only — persist in /etc/nftables.conf)"
        fi
      done
      ;;
    iptables)
      for p in $(printf '%s' "$protos" | tr ',' ' '); do
        case $p in
          tcp) if iptables -w -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                 log_debug "iptables: $port/tcp already allowed"
               else
                 run iptables -w -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
                 log_ok "iptables: allowed $port/tcp"
               fi ;;
          udp) if iptables -w -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
                 log_debug "iptables: $port/udp already allowed"
               else
                 run iptables -w -I INPUT 1 -p udp --dport "$port" -j ACCEPT
                 log_ok "iptables: allowed $port/udp"
               fi ;;
        esac
      done
      log_warn "iptables rules are not persistent: install iptables-persistent or netfilter-persistent save"
      ;;
    none)
      log_warn "no firewall tool found; nothing to open (the host may be unfiltered)"
      ;;
  esac
}

harden_open_vpn_ports() {
  local be port proto
  for be in wireguard xray-reality ss2022 hysteria2 trojan; do
    be_installed "$be" || continue
    port="$(meta_get "$be" PORT)"
    proto="$(meta_get "$be" PROTO)"
    [ -n "$port" ] || continue
    log_info "opening $be port $port/$proto"
    open_port "$port" "$proto"
  done
  if [ -r /etc/vpnctl/sub/meta.env ]; then
    local sp; sp="$(sed -n 's/^PORT=//p' /etc/vpnctl/sub/meta.env | head -n 1)"
    if [ -n "$sp" ]; then open_port "$sp" tcp; fi
  fi
}

harden_lockdown() {
  local kind="$1"
  log_warn "lockdown mode: default-deny inbound"
  case $kind in
    ufw)
      run ufw default deny incoming >/dev/null
      run ufw default allow outgoing >/dev/null
      run ufw --force enable >/dev/null
      ;;
    firewalld)
      run firewall-cmd --permanent --set-target=DROP >/dev/null || log_warn "firewalld: could not set DROP target"
      run firewall-cmd --reload >/dev/null
      ;;
    iptables)
      run iptables -w -P INPUT DROP
      run iptables -w -P FORWARD DROP 2>/dev/null || true
      run iptables -w -A INPUT -i lo -j ACCEPT
      run iptables -w -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      log_warn "lockdown iptables rules are runtime only"
      ;;
    nftables) log_warn "nftables lockdown is not automatic; set policy drop in /etc/nftables.conf" ;;
    none) log_warn "cannot lock down without a firewall tool" ;;
  esac
  # Never leave SSH closed.
  local sshp; sshp="$(ssh_effective_port)"
  open_port "$sshp" tcp
}

# --- ssh -------------------------------------------------------------------

ssh_config_dir() { printf '/etc/ssh/sshd_config.d'; }
ssh_dropin() { printf '%s/99-vpnctl.conf' "$(ssh_config_dir)"; }

ssh_effective_port() {
  if have sshd; then
    sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' && return 0
  fi
  printf '22'
}

ssh_has_keys() {
  local u f
  f="/root/.ssh/authorized_keys"
  if [ -s "$f" ]; then return 0; fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    u="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    if [ -n "$u" ] && [ -s "$u/.ssh/authorized_keys" ]; then return 0; fi
  fi
  return 1
}

harden_ssh() {
  require_cmd sshd
  mkdir -p "$(ssh_config_dir)"
  local dropin; dropin="$(ssh_dropin)"
  local prev="/tmp/vpnctl-prev-sshd.$$"
  if [ -f "$dropin" ]; then
    cp -a "$dropin" "$prev"
    backup_file "$dropin" >/dev/null
  fi
  backup_file /etc/ssh/sshd_config >/dev/null || true

  local disable_pw=1
  if ! ssh_has_keys; then
    if [ "$HARDEN_FORCE_PASSWORD_OFF" = "1" ]; then
      log_warn "no authorized_keys found, but --force-password-off was given"
    else
      disable_pw=0
      log_warn "no authorized_keys found: keeping password authentication enabled"
      log_info "add a key first:  ssh-copy-id root@\$(hostname -I | awk '{print \$1}'), then re-run harden"
    fi
  fi

  # sshd_config.d is ignored unless the main config Includes it. Say so
  # instead of silently writing a drop-in that has no effect.
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' /etc/ssh/sshd_config 2>/dev/null; then
    log_warn "/etc/ssh/sshd_config has no 'Include ...sshd_config.d/*' line: this drop-in may be ignored"
    log_warn "fix: put  Include /etc/ssh/sshd_config.d/*.conf  at the top of /etc/ssh/sshd_config, then re-run"
  fi

  local tmp="/tmp/vpnctl-sshd.$$"
  {
    printf '# managed by vpnctl %s\n' "$VPNCTL_VERSION"
    printf 'PermitRootLogin prohibit-password\n'
    printf 'MaxAuthTries 3\n'
    printf 'LoginGraceTime 20\n'
    printf 'X11Forwarding no\n'
    printf 'AllowAgentForwarding no\n'
    printf 'ClientAliveInterval 300\n'
    printf 'ClientAliveCountMax 2\n'
    if [ "$disable_pw" = "1" ]; then
      printf 'PasswordAuthentication no\n'
      printf 'KbdInteractiveAuthentication no\n'
    fi
    if [ -n "$HARDEN_SSH_PORT" ]; then
      printf 'Port %s\n' "$HARDEN_SSH_PORT"
    fi
  } > "$tmp"
  install_file "$tmp" "$dropin" 0644
  rm -f "$tmp"

  # Validate before touching the running daemon.
  if ! sshd -t; then
    log_err "sshd rejected the new configuration; restoring the previous one"
    if [ -f "$prev" ]; then mv -f "$prev" "$dropin"; else rm -f "$dropin"; fi
    die "ssh hardening aborted (sshd -t failed); nothing was reloaded"
  fi

  local pending_port; pending_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  if [ -n "$HARDEN_SSH_PORT" ] && [ "$pending_port" != "$HARDEN_SSH_PORT" ]; then
    log_err "sshd still reports port ${pending_port:-unknown} after adding Port $HARDEN_SSH_PORT."
    log_err "Your main sshd_config probably sets Port before an Include. Move"
    log_err "'Include /etc/ssh/sshd_config.d/*.conf' to the top of /etc/ssh/sshd_config and retry."
    if [ -f "$prev" ]; then mv -f "$prev" "$dropin"; else rm -f "$dropin"; fi
    die "port change aborted before restart (no lockout)"
  fi

  # Open the new port before restarting, then reload.
  if [ -n "$HARDEN_SSH_PORT" ]; then
    open_port "$HARDEN_SSH_PORT" tcp
  fi

  if systemd_present; then
    run systemctl reload sshd 2>/dev/null || run systemctl reload ssh 2>/dev/null || run systemctl restart ssh 2>/dev/null || true
  else
    run service ssh reload 2>/dev/null || true
  fi

  # Prove the settings actually took effect (catches an ignored drop-in).
  local eff_pw; eff_pw="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')"
  if [ "$disable_pw" = "1" ] && [ "$eff_pw" != "no" ]; then
    log_err "sshd still reports PasswordAuthentication=${eff_pw:-unknown}: the new config was not applied"
    log_err "check that /etc/ssh/sshd_config Includes sshd_config.d/*.conf before its own settings"
  elif [ "$disable_pw" = "1" ]; then
    log_ok "password authentication is disabled (sshd -T confirms)"
  fi

  rm -f "$prev"
  if [ -n "$HARDEN_SSH_PORT" ]; then
    harden_schedule_rollback "$dropin"
  else
    log_ok "sshd reloaded (no port change)"
  fi
}

# --- rollback timer --------------------------------------------------------

harden_rollback_script() { printf '%s/ssh-rollback.sh' "$VPNCTL_LIB_DIR"; }

harden_schedule_rollback() {
  local dropin="$1" script
  script="$(harden_rollback_script)"
  run mkdir -p "$VPNCTL_LIB_DIR"

  local tmp="/tmp/vpnctl-rollback.$$"
  {
    printf '#!/bin/sh\n'
    printf '# vpnctl: restore SSH access if the port change was not confirmed.\n'
    printf 'set -eu\n'
    printf 'rm -f %s\n' "$dropin"
    printf 'systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true\n'
    printf 'logger -t vpnctl "SSH hardening rolled back automatically"\n'
  } > "$tmp"
  install_file "$tmp" "$script" 0755
  rm -f "$tmp"

  if systemd_present; then
    run systemctl stop "$HARDEN_UNIT.timer" >/dev/null 2>&1 || true
    if run systemd-run --unit="$HARDEN_UNIT" --on-active=300 --timer-property=AccuracySec=1s "$script"; then
      log_warn "SSH port changed to $HARDEN_SSH_PORT with an automatic rollback in 5 minutes."
      log_warn "TEST A NEW SSH CONNECTION NOW: ssh -p $HARDEN_SSH_PORT root@<host>"
      log_warn "then cancel the rollback with:  vpnctl harden --confirm"
      log_warn "not confirmed in time -> sshd reverts to its previous configuration"
    else
      log_err "could not schedule the rollback timer; reverting immediately"
      run sh "$script"
      die "port change reverted"
    fi
  else
    log_warn "no systemd: cannot schedule an automatic rollback."
    log_warn "the new port is already open; if you lose access, use the provider console."
  fi
}

harden_cancel_rollback() {
  require_root "harden --confirm"
  if systemd_present; then
    if systemctl stop "$HARDEN_UNIT.timer" >/dev/null 2>&1 || systemctl stop "$HARDEN_UNIT" >/dev/null 2>&1; then
      log_ok "pending SSH rollback cancelled"
    else
      log_info "no pending rollback timer found"
    fi
    run systemctl reset-failed "$HARDEN_UNIT.timer" >/dev/null 2>&1 || true
  fi
  run rm -f "$(harden_rollback_script)"
}

# --- status ----------------------------------------------------------------

harden_status() {
  is_linux || { log_warn "status is only meaningful on the VPS"; return 0; }
  printf '%-16s %s\n' "firewall" "$(firewall_kind)"
  case $(firewall_kind) in
    ufw) ufw status numbered 2>/dev/null | sed 's/^/  /' | head -n 20 ;;
    firewalld) firewall-cmd --list-all 2>/dev/null | sed 's/^/  /' | head -n 20 ;;
    iptables) iptables -w -S INPUT 2>/dev/null | head -n 15 | sed 's/^/  /' ;;
    nftables) nft list chain inet filter input 2>/dev/null | head -n 15 | sed 's/^/  /' ;;
  esac
  printf '%-16s %s\n' "ssh port" "$(ssh_effective_port)"
  printf '%-16s %s\n' "password auth" "$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')"
  printf '%-16s %s\n' "root login" "$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')"
  if [ -f "$(ssh_dropin)" ]; then
    printf '%-16s %s\n' "vpnctl drop-in" "present ($(ssh_dropin))"
  else
    printf '%-16s %s\n' "vpnctl drop-in" "absent"
  fi
  local ports; ports="$(harden_port_list)"
  printf '%-16s %s\n' "vpn ports" "${ports:-<no backends installed>}"
  if systemd_present && systemctl is-active --quiet "$HARDEN_UNIT.timer" 2>/dev/null; then
    printf '%-16s %s\n' "rollback" "PENDING — run: vpnctl harden --confirm"
  fi
}

validate_port_number() {
  case $1 in ''|*[!0-9]*) die "invalid port: '$1'" ;; esac
  if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then die "port out of range: $1"; fi
}
