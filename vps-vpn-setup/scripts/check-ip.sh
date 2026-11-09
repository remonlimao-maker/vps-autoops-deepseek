#!/usr/bin/env bash
# check-ip.sh — 从「你这台设备」判断 VPS 的 IP 是否被封。
#
# 必须在本机跑，不是服务器上：被封的是「你 -> 服务器」这段路。
#
# 判断逻辑（关键是别把服务故障误判成封锁）：
#   服务端口通                  -> ok
#   服务端口不通, SSH 端口通     -> service  （机器活着，别销毁）
#   服务端口不通, SSH 也不通     -> blocked  （IP 级封锁，建议重建）
#   连控制目标都不通             -> local    （你自己的网络问题）
#
#   ./check-ip.sh <IP> [--port 443] [--ssh-port 22] [--control host:port] [--json]
#
# 退出码：0 ok, 10 blocked, 11 service, 12 local

set -uo pipefail

PORT=443
SSH_PORT=22
CONTROL="www.baidu.com:443"     # 国内可达，用来证明「本地网络是好的」
JSON=0
HOST=""

while [ "$#" -gt 0 ]; do
  case $1 in
    --port) PORT="${2:-443}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-22}"; shift 2 ;;
    --control) CONTROL="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) HOST="$1"; shift ;;
  esac
done

[ -n "$HOST" ] || { printf 'usage: check-ip.sh <IP> [--port 443] [--ssh-port 22]\n' >&2; exit 2; }

# 必须在过滤端口上也有硬超时：nc 的 -w/-G 在 macOS 上对 connect 不生效，
# 遇到 DROP 的端口会挂到内核超时（70 秒以上）。
tcp_open() {
  local h="$1" p="$2"
  if command -v perl >/dev/null 2>&1; then
    perl -MIO::Socket::INET -e '
      my $s = IO::Socket::INET->new(PeerAddr => $ARGV[0], PeerPort => $ARGV[1], Timeout => 3);
      exit($s ? 0 : 1);
    ' "$h" "$p" 2>/dev/null && return 0
    return 1
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$h" "$p" >/dev/null 2>&1 && return 0
  fi
  # 最后兜底：bash 的 /dev/tcp + 看门狗
  ( exec 3<>"/dev/tcp/$h/$p" ) 2>/dev/null &
  local pid=$! i=0
  while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; fi
  wait "$pid" 2>/dev/null
}

svc_ok=0; ssh_ok=0; ctl_ok=0
tcp_open "$HOST" "$PORT" && svc_ok=1
tcp_open "$HOST" "$SSH_PORT" && ssh_ok=1
if [ -n "$CONTROL" ]; then
  tcp_open "${CONTROL%%:*}" "${CONTROL##*:}" && ctl_ok=1
else
  ctl_ok=1
fi

if [ "$svc_ok" = "1" ]; then
  verdict="ok"; rc=0
  advice="服务端口 $PORT 可达，IP 正常"
elif [ "$ctl_ok" = "0" ]; then
  verdict="local"; rc=12
  advice="连控制目标 $CONTROL 都不通，先检查你自己的网络（Wi-Fi/流量/本地代理）"
elif [ "$ssh_ok" = "1" ]; then
  verdict="service"; rc=11
  advice="IP 是通的（SSH $SSH_PORT 可连），是服务或端口的问题：查服务状态，不要销毁机器"
else
  verdict="blocked"; rc=10
  advice="服务端口 $PORT 和 SSH $SSH_PORT 都不通，而控制目标可达：这个 IP 被封锁了。换端口/协议无用，需要销毁重建"
fi

if [ "$JSON" = "1" ]; then
  printf '{"ip":"%s","port":%s,"ssh_port":%s,"service_reachable":%s,"ssh_reachable":%s,"control_reachable":%s,"verdict":"%s","advice":"%s"}\n' \
    "$HOST" "$PORT" "$SSH_PORT" \
    "$([ "$svc_ok" = "1" ] && echo true || echo false)" \
    "$([ "$ssh_ok" = "1" ] && echo true || echo false)" \
    "$([ "$ctl_ok" = "1" ] && echo true || echo false)" \
    "$verdict" "$advice"
else
  printf '目标      %s\n' "$HOST"
  printf '  %s/%-5s %s\n' "" "$PORT" "$([ "$svc_ok" = "1" ] && echo '可达' || echo '不可达')"
  printf '  %s/%-5s %s\n' "" "$SSH_PORT" "$([ "$ssh_ok" = "1" ] && echo '可达' || echo '不可达')"
  printf '  控制目标 %s %s\n' "$CONTROL" "$([ "$ctl_ok" = "1" ] && echo '可达' || echo '不可达')"
  printf '\n结论      %s\n' "$verdict"
  printf '处理      %s\n' "$advice"
fi

exit "$rc"
