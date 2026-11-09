# 第一次使用：本地电脑要做什么

假设你拿到了一个订阅链接（形如 `http://1.2.3.4:27008/xxxx/clash.yaml`）和/或一个 `clash.yaml` 文件。
下面按系统写，照着做即可，不需要懂原理。

> **前提**：你需要先能打开客户端官网下载。中国大陆直连 GitHub 可能很慢或打不开——
> 手机端优先用 App Store / 应用商店；桌面端见下面的 **Watt Toolkit 加速**。

## 第 0 步：打不开 GitHub 怎么办

大多数客户端只发布在 GitHub。如果你的网络打不开 GitHub，**先用 Watt Toolkit 把安装包下下来**，
这是国内最常见的做法，装完客户端连上节点后就不需要它了。

**Watt Toolkit（瓦特工具箱，原名 Steam++）**

1. 下载：<https://steampp.net/download>（开源，源码在 GitHub `BeyondDimension/SteamTools`）
2. 支持 **Windows / macOS / Linux**
3. 安装后打开 → 左侧 **网络加速** → 勾选 **GitHub** → 点 **一键加速**
4. 保持它运行，再去下载 Clash Verge Rev 的安装包
5. 客户端装好、能正常上网之后，把它关掉即可

注意：

- 只从 **官网或官方 GitHub Release** 下载，不要用"绿色版""破解版"
- 它通过本地反向代理工作，会接管部分域名和证书；不需要时记得退出
- 它只解决"能下载/能打开 GitHub"，**不是你的 VPN**，不要用它承载日常流量
- 用完关掉，避免和你的代理客户端抢同一个端口

## 选客户端

| 系统 | 推荐 | 备选 |
|---|---|---|
| **Windows** | Clash Verge Rev | v2rayN、NekoRay |
| **macOS** | Clash Verge Rev | ClashX Meta、Mihomo Party |
| **Linux** | Clash Verge Rev（AppImage / deb） | mihomo 命令行、sing-box |
| **iPhone / iPad** | Shadowrocket（付费）、sing-box（免费） | Stash、Karing |
| **Android** | Clash Meta for Android（CMFA） | v2rayNG、NekoBox |

**Clash Verge Rev** 是三平台通用的首选：界面一致、支持订阅链接、内置 mihomo 内核。
官网/GitHub：搜索 `clash-verge-rev`，下载页面里的 `Setup`（Windows）、`.dmg`（macOS）、`.AppImage`/`.deb`（Linux）。

---

## Windows

1. 下载 `Clash.Verge_x.x.x_x64-setup.exe`，双击安装
2. 打开后进入 **订阅 / Profiles** 页面
3. 点右上角 **+** → 选 **从 URL 导入**（Import from URL）
4. 粘贴订阅链接 → 保存
5. 回到 **代理 / Proxies** 页面，选一个节点（`reality-phone` 或 `hy2-phone`）
6. 打开左下角 **系统代理 / System Proxy** 开关
7. 首次运行如果弹 Windows 防火墙提示，选 **允许**

## macOS

1. 下载 `.dmg`，拖进 Applications
2. 首次打开如果提示"无法验证开发者"：系统设置 → 隐私与安全性 → 仍要打开
3. **订阅** → **+** → **从 URL 导入** → 粘贴链接
4. **代理** → 选节点
5. 打开 **系统代理** 开关（有的版本叫"设置为系统代理"）
6. 需要接管所有流量时开启 **TUN 模式**（会请求管理员权限）

## Linux

方式一（图形界面，推荐新手）：

```bash
# AppImage
chmod +x Clash.Verge_*.AppImage && ./Clash.Verge_*.AppImage
# 或 deb
sudo dpkg -i clash-verge_*.deb
```

导入方式与 Windows 相同。

方式二（命令行，无桌面环境）：

```bash
# 用 mihomo 内核直接跑订阅
curl -o config.yaml "<订阅链接>"
mihomo -d . -f config.yaml
# 然后在系统设置或浏览器里把代理指向 127.0.0.1:7890
```

## iPhone / iPad

1. App Store 安装 **Shadowrocket**（付费，约 $2.99）或 **sing-box**（免费）
2. Shadowrocket：首页右上 **+** → 类型选 **Subscribe** → 粘贴链接 → 保存
3. 回到首页，点刚添加的订阅 → 选节点 → 打开顶部开关
4. 首次连接会请求添加 VPN 配置，点 **允许**

## Android

1. 安装 **Clash Meta for Android**（GitHub 下载 APK）
2. 打开 → **配置** → **+** → **从 URL 导入** → 粘贴链接
3. 回首页 → **已停止** → 点一下启动 → 首次会请求 VPN 权限，允许
4. **代理** 页面选节点

## 方式二：用本地 yaml 文件（不是订阅链接）

拿到配置有两种方式，二选一：

| 方式 | 怎么来 | 适合 |
|---|---|---|
| **订阅链接** | 客户端里「从 URL 导入」，服务器更新后客户端点一下同步 | 大多数情况，推荐 |
| **本地 yaml 文件** | 把 `clash.yaml` 拷到自己电脑，手动导入 | 服务器没开订阅服务、想自己改规则、拉不到链接 |

### 文件里有什么

一个 Clash 配置就是四块（参考仓库里的 `assets/profile-template.example.yaml`）：

```yaml
proxies:            # ① 节点：服务器地址、端口、密码/UUID
  - name: "reality-phone"
    type: vless
    server: 1.2.3.4
    port: 443

proxy-groups:       # ② 分组：客户端界面上那个下拉框
  - name: "🚀 节点选择"
    type: select
    proxies: ["reality-phone", "DIRECT"]

rule-providers:     # ③ 规则集：从网上拉的黑白名单（可留空）
  direct:
    type: http
    behavior: domain
    url: "https://.../direct.txt"

rules:              # ④ 规则：从上往下匹配，第一条命中就停
  - DOMAIN-SUFFIX,deepseek.com,DIRECT
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - MATCH,PROXY
```

**只有 `proxies` 是必须的**。其他三块删掉也能用，只是会变成全局代理。

### 新手最常改的三处

**A. 换节点** —— 改 `proxies` 里的 `server` / `port` / `password`。
`name` 改了的话，`proxy-groups` 和 `rules` 里引用它的地方要一起改。

**B. 改分组** —— `proxy-groups` 里 `proxies` 列表就是下拉框的选项。
想让某组默认直连，把 `DIRECT` 放到第一位。

**C. 加一条直连规则** —— 必须放在 `rules:` 的**最前面**：

```yaml
rules:
  - DOMAIN-SUFFIX,deepseek.com,DIRECT      # ← 加这里
  - RULE-SET,proxy,🚀 节点选择              # ← 后面的规则会先截获
  - MATCH,🚀 节点选择
```

放后面会被 `RULE-SET` 或最后的 `MATCH` 抢先匹配，等于没写。这是最常见的错误。

### 导入本地文件

**Clash Verge Rev**：左侧「订阅 / Profiles」→ 右上 **+** → **从文件导入** → 选 `clash.yaml` → 右键该配置 → **设为当前 / Use**。

导入后同样要选节点、打开「系统代理」或 TUN。

### 三个容易踩的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 导入时报 YAML 解析错误 | 用了 **Tab** 缩进 | 全部改成 2 个空格 |
| 新增规则不生效 | 加在了 `MATCH` 后面 | 移到 `rules:` 最前面 |
| 改了节点名就连不上 | `proxy-groups` 还引用旧名字 | 全文替换成新名字 |

> 文件里有节点密码。自己改没问题，别外传、别提交到公开仓库。

---

## 验证是否成功

连上之后，用浏览器打开：

```
https://ipinfo.io
```

看到的国家/城市是**服务器所在地**（比如美国），就说明成功了。
如果还是你本地的 IP，说明客户端没接管流量——检查系统代理开关或 TUN 模式。

## 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 连 GitHub 都打不开，下不了客户端 | 国内直连被阻 | 先装 Watt Toolkit 开 GitHub 加速（见第 0 步） |
| 导入订阅报错 | 链接不完整 / 已失效 | 重新复制完整链接；确认服务器还在运行 |
| 导入成功但没网 | 没开系统代理 / TUN | 打开开关；Windows 检查防火墙是否放行 |
| 部分网站打不开 | 规则把该网站走了直连 | 客户端里把分组切到节点，或检查规则 |
| 国内网站变慢 | 走了代理 | 确认订阅里国内站点是 DIRECT（本项目的订阅默认已配置） |
| 连上几分钟就断 | UDP 被限速 / 节点被干扰 | 换另一个节点；或让服务端加 TCP 通道 |
| macOS 提示"无法验证开发者" | 未签名 | 系统设置 → 隐私与安全性 → 仍要打开 |

## 安全提醒

- **订阅链接就是密码**：任何人拿到都能用你的节点。不要发群、不要截图外传。
- 不要把链接贴到公开的订阅转换网站（等于把它交给第三方）。
- 客户端只从官方渠道下载，不要用"绿色版""破解版"。

## 给 Agent 的提示

交付订阅时，**必须同时给出**：

1. 订阅链接（或文件路径）
2. 用户系统对应的客户端名称
3. 导入步骤（本文件对应章节）
4. 验证方法（`ipinfo.io` 看出口）
5. 回滚/关闭方法

不要只丢一个链接就结束。
