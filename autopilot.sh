#!/usr/bin/env bash
# autopilot.sh — 一条命令跑完整个工作流。
#
# 建机 → 部署 → 出订阅 → 装客户端 → 导入 → 验证
#
# 使用者不需要学任何东西，回答两三个问题（或者什么都不回答，用默认值）即可。
#
#   ./autopilot.sh                      # 新建机器，默认：ChatGPT 用途、$3.5 档、客户端名为 phone
#   ./autopilot.sh --host root@1.2.3.4  # 已经有机器，只部署和配置本机
#   ./autopilot.sh --no-client          # 只做服务端，不装本机客户端
#   ./autopilot.sh --dry-run            # 只看它要做什么
#
# 退出码：0 成功，2 前置条件缺失，4 服务端部署失败，5 客户端步骤失败（服务端已可用）

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPSCTL="$ROOT/vps-provision/scripts/vpsctl"
REMOTE="$ROOT/vps-vpn-setup/scripts/remote.sh"
CLIENTCTL="$ROOT/vps-vpn-setup/scripts/clientctl"

PURPOSE="chatgpt"
CLIENT_NAME="phone"
HOST=""
REGION="auto"
PLAN="auto"
YES=0
DRY=0
SKIP_CLIENT=0

if [ -t 2 ]; then C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_RST=$'\033[0m'
else C_OK=''; C_WARN=''; C_ERR=''; C_B=''; C_D=''; C_RST=''; fi
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_RST" >&2; }
ok()   { printf '%sok%s   %s\n' "$C_OK" "$C_RST" "$*" >&2; }
warn() { printf '%s!!%s   %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
die()  { printf '%serr%s  %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit "${2:-2}"; }

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case $1 in
    --host) HOST="${2:?}"; shift 2 ;;
    --purpose) PURPOSE="${2:-chatgpt}"; shift 2 ;;
    --client) CLIENT_NAME="${2:-phone}"; shift 2 ;;
    --region) REGION="${2:-auto}"; shift 2 ;;
    --plan) PLAN="${2:-auto}"; shift 2 ;;
    --no-client) SKIP_CLIENT=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -r "$VPSCTL" ] || die "找不到 ${VPSCTL}（请在整个仓库根目录运行）"
[ -r "$REMOTE" ]  || die "找不到 $REMOTE"

json_field() { python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(d.get(sys.argv[1],""))' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- 1. 凭据
step "检查凭据"
if [ -z "$HOST" ]; then
  doctor_out="$("$VPSCTL" doctor 2>&1 || true)"
  case $doctor_out in
    *"not set"*)
    warn "还没有 Vultr API Key（建机需要）"
    printf '  跑这一条，然后重试本脚本：\n    %s\n' "$VPSCTL setup-key" >&2
    die "缺少 API Key"
    ;;
  esac
  ok "Vultr API Key 可用"
else
  ok "目标机器 ${HOST}（跳过建机）"
fi

# ---------------------------------------------------------------- 2. 服务端
step "部署服务端"
NAME=""; IP=""

if [ -n "$HOST" ]; then
  IP="${HOST#*@}"
  if [ "$DRY" = "1" ]; then
    printf '  dry run: %s --cn -c %s deploy %s\n' "$REMOTE" "$CLIENT_NAME" "$HOST" >&2
  else
    bash "$REMOTE" --cn -c "$CLIENT_NAME" deploy "$HOST" || die "服务端部署失败" 4
  fi
else
  go_args=(go --purpose "$PURPOSE" --client "$CLIENT_NAME" --yes)
  [ "$REGION" != "auto" ] && go_args+=(--region "$REGION")
  [ "$PLAN" != "auto" ] && go_args+=(--plan "$PLAN")
  if [ "$DRY" = "1" ]; then
    printf '  dry run: %s %s\n' "$VPSCTL" "${go_args[*]}" >&2
  else
    out="$("$VPSCTL" --json "${go_args[@]}" 2>/dev/null)" || die "建机或部署失败" 4
    NAME="$(printf '%s' "$out" | json_field instance)"
    IP="$(printf '%s' "$out" | json_field ip)"
    if [ -z "$NAME" ]; then
      latest="$(ls -t "$HOME/.vpsctl/instances/"*.env 2>/dev/null | head -1)"
      [ -n "$latest" ] && NAME="$(basename "$latest" .env)"
    fi
    [ -n "$IP" ] || die "部署完成但拿不到 IP" 4
    ok "机器 $NAME ($IP)"
  fi
fi

[ "$DRY" = "1" ] && { step "dry run 结束"; exit 0; }

# ---------------------------------------------------------------- 3. 订阅
step "获取订阅链接"
URL=""
if [ -n "$HOST" ]; then
  URL="$(bash "$REMOTE" run "$HOST" 'cat /etc/vpnctl/sub/url.txt 2>/dev/null' 2>/dev/null | tr -d '\r\n' || true)"
fi
if [ -z "$URL" ] && [ -n "$IP" ]; then
  KEY="$(sed -n 's/^SSH_KEY_FILE=//p' "$HOME/.vpsctl/instances/$NAME.env" 2>/dev/null)"
  KEY="${KEY:-$HOME/.ssh/id_ed25519}"
  URL="$(ssh -i "${KEY%.pub}" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        "root@$IP" 'cat /etc/vpnctl/sub/url.txt 2>/dev/null' 2>/dev/null | tr -d '\r\n' || true)"
fi
if [ -z "$URL" ]; then
  warn "没有找到订阅链接（订阅服务可能未开启）"
  warn "服务端已可用；需要链接时在服务器上跑：vpnctl sub --name $CLIENT_NAME --serve"
  exit 0
fi
SUB="$URL/clash.yaml"
ok "订阅：$SUB"

# ---------------------------------------------------------------- 4. 本机客户端
if [ "$SKIP_CLIENT" = "1" ]; then
  step "跳过本机客户端（--no-client）"
else
  step "配置本机客户端"
  if bash "$CLIENTCTL" all "$SUB" --name "$CLIENT_NAME"; then
    ok "客户端已安装并请求导入"
  else
    warn "客户端步骤没成功——服务端是好的，链接在上面，手动导入即可"
    exit 5
  fi
fi

# ---------------------------------------------------------------- 5. 验证
step "验证"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SUB" 2>/dev/null)"
[ "$code" = "200" ] && ok "订阅可访问（HTTP 200）" || warn "订阅返回 ${code}，检查服务器状态"

printf '\n%s完成%s\n' "$C_B" "$C_RST" >&2
printf '  服务端    %s\n' "${IP:-已部署}" >&2
printf '  订阅      %s\n' "$SUB" >&2
printf '  客户端    %s\n' "$([ "$SKIP_CLIENT" = "1" ] && echo '未处理' || echo '已安装，等待你在界面里确认')" >&2
printf '\n最后两步（客户端里点一下）：\n' >&2
printf '  1. 订阅列表里选中刚导入的配置 → 右键「设为当前」\n' >&2
printf '  2. 打开「系统代理」或「TUN 模式」\n' >&2
printf '  3. 打开 https://ipinfo.io 确认出口是服务器所在地\n' >&2
