# vps-provision

`vpsctl`：用命令行创建、查看、销毁云主机，并把新机器交给 `vps-vpn-setup` 一键配置。

```
SKILL.md              Agent 入口
scripts/vpsctl        唯一命令入口
scripts/lib/common.sh 日志、状态、JSON
scripts/lib/vultr.sh  Vultr API v2（8 个函数，可替换）
references/providers.md  厂商接口约定 + 如何接 DigitalOcean/Hetzner
tests/smoke.sh        假 API，53 项断言，不花钱
```

## 一句话

```bash
./scripts/vpsctl go --purpose chatgpt --yes
```

自动选区域/套餐/系统 → 建机 → 装 VPN → 套你的 Clash 配置 → 拉回客户端文件。
参数全部有默认值，不用回答任何问题。

## 30 秒上手

```bash
./scripts/vpsctl setup-key          # 粘贴一次 API Key（隐藏输入，自动校验，0600）
cd vps-provision
bash tests/smoke.sh                 # 本机自检，不联网

./scripts/vpsctl regions | head
./scripts/vpsctl os | grep -i debian
./scripts/vpsctl create --name jp1 --region nrt --plan vc2-1c-1gb --os 2136
./scripts/vpsctl ssh jp1
```

从零到节点：

```bash
export VPN_SKILL_DIR="../vps-vpn-setup"
./scripts/vpsctl up --name jp1 --region nrt --plan vc2-1c-1gb --os 2136 --cn --client phone
# 结束时 ./vpn-clients 里就是可导入的配置
```

## 设计原则

- **先报价再创建**：确认前打印套餐月价，避免「我以为按小时」。
- **销毁要过两道**：确认 + 重新输入实例名（`--yes` 才跳过）。
- **状态在本地**：`~/.vpsctl/instances/*.env`，不依赖 provider 的 label 查询。
- **不存密钥**：`VULTR_API_KEY` 只从环境读。
- **可替换厂商**：`vultr.sh` 是 8 个函数的薄封装，换云厂商不动主程序。
- **dry-run 可信**：`--dry-run` 只打印 API 调用，不建实例、不写状态。

## 边界

- 目前只实现 Vultr；DigitalOcean / Hetzner / 阿里云需要按 `references/providers.md` 补一个 `lib/<provider>.sh`。
- 不做账单管理、不做快照恢复（快照创建有，恢复在控制台做）。
- 不替用户注册账号、绑卡、验证身份。
