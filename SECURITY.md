# 安全约定

## 凭据边界

以下内容视为**最高级别机密**，只允许存在于目标主机的受限文件或用户自己的设备上：

- 服务器私钥：`/etc/vpnctl/*/server.key`、`/etc/wireguard/*.conf`、`/etc/hysteria/key.pem`、Trojan 的 `tls/key.pem`
- 客户端凭据：`/etc/vpnctl/*/clients/*.env`、`~/vpn-clients/**`、`clash.yaml`、`v2ray.txt`、`uris.txt`
- SSH 私钥、云厂商 API Token、Cloudflare Token

规则：

1. 不打印到终端、不写进对话、不提交 Git、不发到第三方「在线转换/二维码」网站。
2. 订阅链接与配置本身就是 bearer 凭据，Base64 不是加密。
3. 交付方式只有：`scp` 取回、本地生成二维码、用户自己的私有存储。
4. 日志与截图中出现密钥即视为泄漏，按轮换处理（`client remove` + `client add`）。

## 工具侧的保证

- 状态目录 `/etc/vpnctl` 为 `0700`，密钥文件 `0600`；`vpnctl` 的 stdout 默认不含密钥。
- 云 API 凭据默认只从环境变量读取。唯一的例外是 `~/.vpsctl/vultr.key`——GUI 启动的 Agent 继承不到 shell 环境变量，没有这个文件就无法一键建机。该文件必须 `0600`，工具发现权限过宽会告警。
- `probe` / `plan` / `verify` / `client list` 只读，不改变主机，也不创建状态目录。
- 二进制来自官方 GitHub release，有 `.dgst` 时校验 sha256，失败即中止。
- 不执行 `curl | bash`，不引入第三方一键脚本。

## 主机侧的建议

- 默认拒绝入站，只放行 SSH 与已安装后端的端口（`vpnctl harden --lockdown`）。
- 无 `authorized_keys` 时不关闭密码登录；改 SSH 端口必须带自动回滚。
- 云厂商安全组与本机防火墙是两层，都要配。
- 不记录用户访问日志（Xray `access: none`，Hysteria2 只留错误）。

## 报告问题

发现安全问题请开 issue 或在私信中说明**复现方式与影响范围**，不要附带任何真实密钥、订阅内容、主机地址或日志原文。示例一律使用文档保留地址（`192.0.2.0/24`、`203.0.113.0/24`、`vpn.example.com`）。

## 使用边界

- 仅供用户在自己拥有或明确获授权的服务器上使用。
- 使用者需自行确认当地法律与云厂商 AUP 允许该用途。
- 不用于攻击、扫描、垃圾邮件或转售流量。
