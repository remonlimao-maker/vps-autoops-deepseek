# 第一次用：从零到能上网

这份文档给**完全没接触过 VPS、没注册过 Vultr、没用过终端**的人。
照着做，不需要理解原理；需要你动手的地方只有“注册/充值/粘贴一次 API Key”。

> 下面所有命令默认在**仓库根目录**（解压后的 `vps-autoops-deepseek`）执行；
> 路径不对时先 `cd` 到那个目录。

## 你会经历什么

| 阶段 | 谁来做 | 大约时间 |
|---|---|---|
| 注册 Vultr、充值、创建 API Key | **你**（约 10 分钟） | 10 分钟 |
| 建机、装 VPN、验证 | AI 自动执行 | 10–15 分钟 |
| 电脑/手机导入客户端 | 你点几下，或 AI 代劳 Mac | 5 分钟 |

费用：

| 套餐 | 配置 | 月费 | 说明 |
|---|---|---|---|
| `vc2-1c-0.5gb` | 1 vCPU / 512MB / 10GB | **$3.5** | 只上 ChatGPT/YouTube，单用户；仅美国 `ewr` |
| `vc2-1c-1gb` | 1 vCPU / 1GB / 25GB | **$5** | 日本/新加坡/美国，多设备更稳 |
| `vc2-1c-2gb` | 1 vCPU / 2GB / 55GB | **$10** | 多人、多节点 |

- **只访问 ChatGPT 等、自己用：推荐 $3.5 档**；但要说明日本/新加坡最低 $5。
- 先充 **$10 左右**，这是**余额**，不是手续费；按小时扣，跑一天约 $0.12–$0.17。
- 测试完当天销毁，通常只花几分钱；`vpsctl destroy <名字> --yes` 停止计费。

## 开始前，确认三件事

1. **你有一个能执行命令的 AI**
   - DeepSeek Harness（DSH）、Claude Code、Codex 等
   - Windows 需要 **WSL2** 或 **Git Bash**；macOS 用自带“终端”
   - 如果 AI 只能聊天、不能执行命令，见 `../assets/prompts/chat-only.md`，需要你手动复制命令

2. **你有没有一台现成的 VPS？**
   - 有：只需要 IP、SSH 端口、用户名、私钥或密码；**不需要 Vultr 账号**
   - 没有：继续看第 2 步

3. **你有没有 Vultr 账号和支付方式？**
   - 有账号：只差一个 API Key
   - 没有账号：需要邮箱 + 信用卡/PayPal（部分地区支付宝）

## 第 1 步：把入口提示词发给 AI

打开 [`../assets/ENTRY-PROMPT.md`](../assets/ENTRY-PROMPT.md)，复制“中文版”整段，把仓库地址换成你的路径，发给 AI。

AI 会先问你：

```text
1. 你现在有可用的 VPS 吗？
2. 没有的话，有 Vultr 账号吗？
```

如实回答即可。**没有账号时，AI 会给你注册步骤，然后停下来等你**，不会直接建机。

## 第 2 步：注册 Vultr（没有账号才做）

1. 打开 <https://www.vultr.com> → **Sign Up** → 邮箱验证
2. 右上头像 → **Billing** → **Add Funds**，通常 **$10 起**
   - 信用卡 / PayPal，部分地区支付宝（以页面为准）
   - **不充值不能开机**
3. 右上头像 → **Account** → **API Keys** → **Add API Key**
   - 权限选 **Read & Write**
   - IP Access 选 **Allow all IPv4**（否则脚本连不上）
4. **不要把 API Key 贴进聊天框**。在终端运行：

   ```bash
   bash vps-provision/scripts/vpsctl setup-key
   ```

   它会隐藏输入、自动校验、存成 0600。
5. 验证：

   ```bash
   bash vps-provision/scripts/vpsctl doctor
   ```

   看到 `API key set` 和 `API call ok` 才算完成。

完整图文（含报错对照）：[`vultr-setup.md`](../../vps-provision/references/vultr-setup.md)。

## 第 3 步：AI 建机与部署

账号/Key 准备好后，回到 AI 说“好了，继续”。接下来：

1. AI 会先把 **0.5GB/$3.5、1GB/$5、2GB/$10** 的价格和可用区域列给你看，再创建机器；
   只上 ChatGPT 推荐 $3.5（仅 `ewr`），要日本/新加坡低延迟选 $5
2. 先做**只读体检**：SSH、端口、系统、目标站点
3. 把“要改什么、风险、怎么回滚”列给你，**等你授权**
4. 授权后才安装、开端口、建客户端、验证
5. 最后给你订阅链接 + 客户端导入步骤

中途不需要你敲命令（除了 `setup-key` 粘贴 Key）。

## 第 4 步：客户端导入

| 你的设备 | 客户端 | 导入 |
|---|---|---|
| macOS / Windows / Linux | **Clash Verge Rev** | 订阅 → 从 URL 导入 |
| iPhone | Shadowrocket / **sing-box** | sing-box 导入 `singbox.json` |
| Android | Clash Meta for Android / **sing-box** | 同上 |

详细步骤（含截图级说明、验证、注意事项）：
[`getting-started.md`](getting-started.md) 的「手机端：sing-box」和客户端章节。

验证：

- 打开 YouTube / ChatGPT 能加载 → 代理通
- 打开百度能访问 → 国内直连正常
- `ipinfo.io` 只作参考：白名单模式显示国内 IP 是正常的

## 第 5 步：不用了怎么停

```bash
# 看当前实例和月费估算
bash vps-provision/scripts/vpsctl cost

# 销毁（不可恢复，IP 会释放；停止计费）
bash vps-provision/scripts/vpsctl destroy <名字> --yes
```

按小时计费，**销毁后停止**；已经跑过的小时数照常结算。
快照、备份、保留 IP 是另外的费用，默认都没开。

## 新手最常见卡点

| 现象 | 原因 | 怎么办 |
|---|---|---|
| AI 直接报错/要 API Key | 还没配 Key | 先做第 2 步，`vpsctl setup-key` |
| `401` | Key 错/被删 | 重新建 Key，再 `setup-key` |
| `403` | 账号限额/未验证/没充值 | 控制台绑卡、验证、充值 |
| SSH 连不上 | 安全组没放行 / 密钥不对 | 检查云防火墙、密钥；用 VNC 控制台 |
| GitHub 下载慢 | 国内网络 | 换网络或用镜像；见 `troubleshooting.md` |
| 手机导入失败 | App 版本旧 / 链接不完整 | sing-box 升级到 1.10+，核对链接 |
| 连上但某个站打不开 | 白名单没收录 | 让 AI 加一条规则重新生成 |
| 账单看不懂 | 按小时、月账单 | 看 `pending_charges`；$3.5–$5 是月估算 |

## 避免 ChatGPT 被封号

- **优先美区出口**：`ewr` / `lax` / `sjc` / `sea`；香港不建议，日本/新加坡次之
- **固定一个节点/IP**：不要频繁换国家、重建机器或来回切订阅
- **不要共享订阅链接**：多人共用一个出口登录多个账号，风控概率高
- 账号注册地 / 支付方式尽量与出口一致；美区账号优先美区
- 不要拿这个 IP 做爬虫、批量注册、试用滥用
- 以上只能降低概率，**不能保证不封号**；`check-sites` 只测网络可达

## 安全底线

- API Key、私钥、订阅链接**不要发群、不要截图**
- 不要买/借别人的 Vultr 账号或 API Key
- 不要让 AI 代填支付信息
- 不用来源不明的“一键脚本”；本项目只从官方 release 下载并校验
