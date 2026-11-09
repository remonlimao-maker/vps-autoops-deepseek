# 厂商接口

`vpsctl` 不直接写死某家云，它只调用 `lib/<provider>.sh` 里的 8 个函数。想接 DigitalOcean、Hetzner、阿里云，补一个同签名的文件即可。

## 函数契约

| 函数 | 输入 | 输出（stdout） | 说明 |
|---|---|---|---|
| `vultr_regions` | — | 每行 `id\|city\|country` | 区域列表 |
| `vultr_plans` | — | 每行 `id\|vcpu\|ram_mb\|disk_gb\|monthly_usd\|regions_csv` | 套餐与价格 |
| `vultr_os` | — | 每行 `id\|name\|arch` | 系统镜像 |
| `vultr_ssh_keys` | — | 每行 `id\|name` | 已注册公钥 |
| `vultr_ensure_key FILE NAME` | 公钥路径、钥匙名 | 一行 `key_id` | 已存在则复用，不存在才注册 |
| `vultr_create REGION PLAN OS_ID LABEL KEY_ID` | — | 一行 `instance_id` | 只负责创建，不等待 |
| `vultr_instance ID` | — | 一行 `status\|ip\|label\|region\|plan\|monthly\|created` | 查询状态 |
| `vultr_delete ID` / `vultr_reboot ID` / `vultr_snapshot ID DESC` | — | 删除/重启无输出；快照返回 `id\|desc` | 生命周期 |

约定：

- **失败返回非零**，错误信息走 stderr，不要污染 stdout。
- 所有响应解析用 python3（`_py` 助手），不要依赖 jq。
- 价格用**数字**（美元/月），格式由主程序负责。
- 不要在这里做确认、等待、重试；那是主程序的职责。

## Vultr API v2 速查

基址 `https://api.vultr.com/v2`，认证头 `Authorization: Bearer $VULTR_API_KEY`。

| 动作 | 请求 |
|---|---|
| 区域 | `GET /regions` |
| 套餐 | `GET /plans` |
| 镜像 | `GET /os` |
| 公钥 | `GET /ssh-keys`、`POST /ssh-keys {name, ssh_key}` |
| 创建 | `POST /instances {region, plan, os_id, label, hostname, sshkey_ids, backups:"disabled", enable_ipv6}` |
| 查询 | `GET /instances/{id}` → `status`, `main_ip` |
| 重启 | `POST /instances/{id}/reboot` |
| 快照 | `POST /instances/{id}/snapshot {description}` |
| 删除 | `DELETE /instances/{id}` |

状态机：`pending` → `installing` → `active`。`main_ip` 在 `active` 之前是 `0.0.0.0`，`vpsctl` 会等到非零。

## 接入 DigitalOcean（示例骨架）

```bash
# scripts/lib/do.sh
DO_API_BASE="https://api.digitalocean.com/v2"

do_api() {  # METHOD PATH [BODY]，与 vultr_api 同签名
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" "$DO_API_BASE$path"
}

do_regions() {
  do_api GET /regions | _py '
import json,sys
for r in json.load(sys.stdin).get("regions", []):
    if r.get("available"):
        print("%s|%s|%s" % (r["slug"], r.get("name",""), r.get("continent","")))
'
}
# ... rest of the 8 functions
```

然后在 `vpsctl` 里：

```bash
load_provider() {
  case $PROVIDER in
    vultr) . "$LIB_DIR/vultr.sh"; vultr_require_key ;;
    digitalocean) . "$LIB_DIR/do.sh"; do_require_token ;;
    *) die "unknown provider '$PROVIDER'" ;;
  esac
}
```

并让 `cmd_*` 通过 `provider_<verb>` 间接调用，而不是写死 `vultr_`：

```bash
provider_create() { "${PROVIDER}_create" "$@"; }
```

`tests/smoke.sh` 的假 `curl` 只认 `api.vultr.com`，接新厂商时按同样方式加一个分支即可。

## 各家差异备忘

| 厂商 | 认证 | 创建接口 | 计费粒度 | 备注 |
|---|---|---|---|---|
| Vultr | Bearer Token | `POST /instances` | 按小时 | 有快照、保留 IP 另收费 |
| DigitalOcean | Bearer Token | `POST /droplets` | 按小时 | 删除后快照另存 |
| Hetzner Cloud | `Authorization: Bearer` | `POST /servers` | 按小时（有月封顶） | 价格更低，亚洲机房少 |
| 阿里云/腾讯云 | 签名（AK/SK） | OpenAPI | 按量/包月 | 签名复杂，建议用官方 CLI 包装 |

最后一行是实话：国内云的 OpenAPI 签名自己实现容易出错，包一层官方 CLI 更稳，也便于审计。
