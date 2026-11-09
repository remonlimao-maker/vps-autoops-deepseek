# Vultr 账号与 API Key（以 Vultr 为例）

本项目的 `vps-provision` 用 **Vultr** 作为默认云厂商。这份文档带你走完「从零到拿到 API Key」，
大约 10 分钟，只有这一步需要你亲自动手。

> 已经有别的服务器（阿里云、腾讯云、搬瓦工、Hetzner……）？
> **跳过这份文档**，直接用 `vps-vpn-setup/scripts/remote.sh deploy root@你的IP --cn -c phone`，
> 不需要 Vultr 账号。

---

## 1. 注册账号

1. 打开 <https://www.vultr.com>，点右上角 **Sign Up**
2. 填邮箱 + 密码（或用 Google / GitHub 账号登录）
3. 去邮箱点验证链接

注册后账号是空的，**不充值不能开机**。

## 2. 充值

1. 登录后右上角头像 → **Billing**
2. **Add Funds**（充值）
3. 金额：通常 **$10 起**，支持信用卡 / PayPal，部分地区支持支付宝——**以页面显示为准**
4. 完成支付

> 计费是**按小时**的：$3.5/月的机型，跑一天约 $0.12，销毁后停止计费。
> 不开 Backup、不加 Block Storage、不买 Reserved IP，就不会有额外费用。

## 3. 创建 API Key

这是一串字母数字，作用是**让脚本代替你登录控制台开机器**。不需要给任何人。

1. 打开 <https://my.vultr.com/settings/#settingsapi>
   （或：右上角头像 → **Account** → 左侧 **API Keys**）
2. 点 **Add API Key**
3. 填两项，**都很关键**：

   | 字段 | 选什么 | 选错会怎样 |
   |---|---|---|
   | **Name** | 随便，例如 `deepseek-harness` | 无影响 |
   | **Permissions** | **Read & Write**（默认常是 Read Only） | 只读的 Key 能查询、不能建机，会在部署时报 401 |
   | **IP Access** | **Allow all IPv4** | 只允许特定 IP 时，换网络就报 `Unauthorized IP address` |

4. 点 **Add**，页面会显示完整 Key —— **当场复制**。
   离开这个页面后就只显示缩略（`N3A…`），再也看不到完整值。

> 复制到的是一长串字母数字（约 36 位）。**不要**复制 Key 的名字，也不要复制缩略值。

## 4. 保存到本机

在仓库目录下运行：

```bash
bash vps-provision/scripts/vpsctl setup-key
```

它会：

1. 提示 `Paste the Vultr API key (input hidden)` —— **输入不显示**，粘贴后回车
2. 先验证能不能查询（读权限）
3. 再验证能不能写入（写权限）
4. 两项都过才保存到 `~/.vpsctl/vultr.key`（权限 600）
5. 任一项失败立刻报错，**不会留下坏文件**

## 5. 验证

```bash
bash vps-provision/scripts/vpsctl doctor
```

期望输出：

```
  API key     set (N3A...)
  API call    ok
ok doctor: no problems found
```

看到这两行就可以开始建机了：

```bash
./autopilot.sh            # 或在 vps-provision 里跑 ./scripts/vpsctl go --purpose chatgpt --yes
```

---

## 常见错误对照

| 报错 | 原因 | 解决 |
|---|---|---|
| `Invalid API token` | 复制的是缩略值 / Key 名字 / 已撤销的旧 Key | 回页面**新建**一个，当场复制完整值 |
| `Unauthorized IP address: x.x.x.x` | IP Access 限制了来源 IP | 把该 Key 的 IP Access 改成 **Allow all IPv4**（出口 IP 会变，别只加单个） |
| `this key is READ-ONLY` | 权限选了 Read Only | 新建一个 **Read & Write** 的 Key |
| `403` | 账号限额 / 欠费 | 看 Billing 页，充值或提额 |
| `429` | 请求太频繁 | 等一分钟后重试 |

> 本项目**不需要** Key 的 `IP Access` 只开某个 IP——出口 IP 会变，那样只会给自己添麻烦。

## 安全建议

1. Key 等于账号操作权限，**不要**贴到聊天、群里、公开仓库。
2. 本项目把它存成 `~/.vpsctl/vultr.key`（600），因为图形界面启动的 Agent 读不到环境变量。
3. 不想用了：Vultr 控制台删除该 Key 即可，本机文件也删掉。
4. 定期轮换：新建一个 → `setup-key` 覆盖 → 控制台删旧的。
5. 不要给 Key 开超出需要的权限。

## 不想用 API Key？

完全可以。在 Vultr 网页控制台手动开一台机器，拿到 IP 后：

```bash
cd vps-vpn-setup
bash scripts/remote.sh --cn -c phone deploy root@<你的IP>
```

功能一样（装 VPN、出订阅、装本机客户端），只是**少了「创建 / 销毁 / 快照」**这部分自动化。

## 其他云厂商

`vps-provision` 目前只实现了 Vultr。接别家看 `references/providers.md`——需要实现 8 个函数，
主程序不用改。国内云（阿里云/腾讯云）的 OpenAPI 签名较复杂，建议包一层官方 CLI。
