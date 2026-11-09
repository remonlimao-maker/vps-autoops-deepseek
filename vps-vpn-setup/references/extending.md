# 扩展：新增一个后端

`vpnctl` 的后端是「一组函数 + 一个状态目录」的约定，没有插件框架。新增协议只需实现同一组函数并在两处注册。

## 1. 后端契约

文件：`scripts/lib/backend-<id>.sh`，由 `scripts/vpnctl` 的 `load_backend` 按 id 加载。加载时设置 `BE_ID`，必要时设置 `BE_VARIANT`。

必须实现：

| 函数 | 职责 | 副作用 |
|---|---|---|
| `be_parse_opts "$@"` | 解析后端专属参数并校验 | 无 |
| `be_help` | 打印参数帮助 | 无 |
| `be_print_plan` | 人类可读的执行计划 | 无 |
| `be_install` | 幂等安装/重配 | 有（受 `--dry-run` 约束） |
| `be_client_add NAME` | 写入客户端记录并生效 | 有 |
| `be_client_remove NAME` | 删除记录并生效 | 有 |
| `be_client_export NAME [DIR]` | 生成交付文件 | 有（只写 `~/vpn-clients`） |
| `be_verify` | 健康检查，`0`/非 `0`，支持 `--json` | 无 |
| `be_uninstall` | 停服务、移除配置、保留状态 | 有 |

可选：

| 函数 | 用途 |
|---|---|
| `be_from_state` | 命令启动时从 `meta.env` 恢复参数（客户端指令要用同一端口/密钥时必需） |
| `be_info` | `id\|名称\|传输层\|默认端口`，供文档与列表使用 |

## 2. 状态约定

- 状态根：`/etc/vpnctl/<id>/`（`700`）。
- `meta.env`：`KEY=VALUE`，用 `meta_set`/`meta_get` 读写。至少写：
  `PORT`、`PROTO`（`tcp`/`udp`/`tcp,udp`）、`PUBLIC_IP`、`CONFIG`、`SERVICE`、`PUBKEY`（如有）。
  `harden` 靠 `PORT`/`PROTO` 自动放行端口。
- 服务器密钥：`/etc/vpnctl/<id>/server.key`（`600`）。
- 客户端：`/etc/vpnctl/<id>/clients/<name>.env`，用 `client_write`/`client_get`/`client_list`。
- 交付物：`${HOME}/vpn-clients/<id>/<name>/`，文件 `600`。

## 3. 三条硬约束

1. **一切副作用走 `run`**，这样 `--dry-run` 才可信：`run systemctl restart foo`，不要直接调用。
2. **覆盖前先备份**：用 `install_file`（自带备份 + 原子替换）而不是 `cp`。
3. **stdout 只放机器可读内容**（JSON/配置/路径），进度日志走 `log_*`（stderr）。

## 4. 注册

```bash
# scripts/vpnctl
BACKENDS="wireguard xray-reality ss2022 hysteria2 trojan"

load_backend() {
  case $be in
    ...
    trojan) . "$LIB_DIR/backend-trojan.sh" ;;
  esac
}
```

`harden.sh` 的 `harden_port_list` 与 `harden_open_vpn_ports` 用显式 case 映射协议，如新后端需要特殊端口组合，在那里补一行。

## 5. 最小示例

```bash
#!/usr/bin/env bash
# vpnctl backend: Trojan (example skeleton)

TJ_PORT="${TJ_PORT:-8443}"
TJ_CONF="/usr/local/etc/trojan/config.json"
TJ_UNIT="/etc/systemd/system/trojan.service"
TJ_BIN="/usr/local/bin/trojan"

be_parse_opts() {
  while [ "$#" -gt 0 ]; do
    case $1 in
      --port) TJ_PORT="${2:-}"; shift 2 ;;
      -h|--help) be_help; exit 0 ;;
      *) die "trojan: unknown option '$1'" ;;
    esac
  done
  case $TJ_PORT in ''|*[!0-9]*) die "invalid port: '$TJ_PORT'" ;; esac
}

be_help() { printf 'trojan options:\n  --port N   (default %s)\n' "$TJ_PORT"; }

be_print_plan() {
  cat <<EOF
Plan: trojan
  1. install binary -> $TJ_BIN
  2. write $TJ_CONF (port $TJ_PORT)
  3. enable trojan.service
EOF
}

be_from_state() {
  local v; v="$(meta_get trojan PORT)"; [ -n "$v" ] && TJ_PORT="$v"; return 0
}

be_install() {
  meta_init trojan
  # ensure_pkgs curl
  # install the binary (checksum-verified) ...
  meta_set trojan PORT "$TJ_PORT"
  meta_set trojan PROTO "tcp"
  meta_set trojan SERVICE "trojan"
  # render config with printf, then:
  #   printf '...' > /tmp/x.$$ && install_file /tmp/x.$$ "$TJ_CONF" 0600
  # svc_enable_now trojan
  log_ok "trojan configured on $TJ_PORT"
}

be_client_add() { client_write trojan "$1" "PASSWORD=$(rand_hex 16)"; log_ok "added $1"; }
be_client_remove() { rm -f "$(client_file trojan "$1")"; }
be_client_export() {
  local name="$1" dir="${2:-${HOME:-/root}/vpn-clients/trojan/$1}"
  mkdir -p "$dir"
  printf 'trojan://%s@%s:%s#%s\n' "$(client_get trojan "$name" PASSWORD)" \
    "$(meta_get trojan PUBLIC_IP)" "$TJ_PORT" "$name" > "$dir/uri.txt"
  chmod 600 "$dir/uri.txt"; printf '%s\n' "$dir/uri.txt"
}
be_verify() { svc_active trojan; }
be_uninstall() { svc_stop_disable trojan; run rm -f "$TJ_CONF" "$TJ_UNIT"; }
```

## 6. 测试新后端

`tests/smoke.sh` 不碰真实硬件：它用假的 `systemctl`/`wg`/`xray` 等命令替换 PATH，只验证「渲染出的配置正确、dry-run 不产生副作用、名称校验生效」。新增后端时补一条 render 断言：

```bash
assert_file_contains "$out/config.json" '"port": 8443'
```

```bash
bash tests/smoke.sh
```
