# 第一次使用：本地电脑要做什么

假设你拿到了一个订阅链接（形如 `http://1.2.3.4:27008/xxxx/clash.yaml`）和/或一个 `clash.yaml` 文件。
下面按系统写，照着做即可，不需要懂原理。

> **前提**：你需要先能打开客户端官网下载。中国大陆直连 GitHub 可能很慢或打不开——
> 手机端优先用 App Store / 应用商店；桌面端如果下载不动，先找个能上网的地方下载安装包，
> 或者用 Gitee 镜像搜索同名项目。

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
