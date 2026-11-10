#!/usr/bin/env python3
"""Render the deterministic sing-box profile used by phones.

This profile is intentionally narrow and boring:

  * one Hysteria2 outbound, no selector and no mixed protocols;
  * TUN with IPv4 + IPv6, MTU 1400, IPv6 rejected so apps fall back to IPv4;
  * no fake-IP DNS, old-format DNS servers for sing-box 1.10/1.11;
  * CN apps (especially ByteDance/Toutiao) direct, everything else proxied;
  * rule sets served from the subscription endpoint, never GitHub at runtime.

The last point matters in mainland China: raw.githubusercontent.com is often
unreachable, and a phone that cannot download geosite/geoip silently loses its
CN-direct rules and sends domestic apps through the overseas exit.
"""

import argparse
import json

BYTEDANCE_SUFFIX = [
    "toutiao.com", "toutiaoimg.com", "toutiaostatic.com", "toutiaovod.com",
    "toutiaoapi.com", "toutiaocdn.com", "snssdk.com", "pstatp.com",
    "bytedance.com", "bytedance.net", "bytecdn.cn", "byteimg.com",
    "bytescm.com", "bytednsdoc.com", "bytegoofy.com", "ixigua.com",
    "ixiguavideo.com", "bdxiguavod.com", "bdxiguaimg.com", "douyin.com",
    "douyincdn.com", "douyinvod.com", "douyinpic.com", "douyinstatic.com",
    "amemv.com", "iesdouyin.com", "zjcdn.com", "volccdn.com",
    "volcengine.com",
]

BYTEDANCE_KEYWORDS = [
    "toutiao", "snssdk", "pstatp", "bytedance", "byteimg", "bytecdn",
    "bytescm", "bytednsdoc", "bytegoofy", "ixigua", "xigua", "douyin",
    "zjcdn", "volccdn", "volcengine",
]

CN_APP_SUFFIX = [
    "xiaohongshu.com", "xhscdn.com", "xingin.com", "xhimg.com",
    "xiaohongshu.cn",
]

MICROSOFT_SUFFIX = [
    "login.live.com", "login.microsoftonline.com", "account.live.com",
    "acctcdn.msauth.net", "outlook.live.com", "outlook.office365.com",
    "outlook.office.com", "office.com", "office365.com", "msauth.net",
    "microsoftonline.com",
]

CN_KEYWORDS = [
    "baidu", "taobao", "alipay", "qq", "weixin", "bilibili", "bytedance",
    "zhihu", "jd", "meituan", "douyin", "pinduoduo", "toutiao", "snssdk",
    "pstatp", "ixigua", "xigua", "zjcdn", "volccdn", "volcengine",
]

PROXY_KEYWORDS = [
    "openai", "youtube", "netflix", "disney", "hbo", "spotify", "github",
    "twitter", "facebook", "grok",
]

PROXY_SUFFIX = [
    "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com",
    "anthropic.com", "claude.ai", "youtube.com", "youtu.be",
    "googlevideo.com", "ytimg.com", "ggpht.com", "google.com",
    "googleapis.com", "gstatic.com", "googleusercontent.com",
    "gemini.google.com", "bard.google.com", "github.com",
    "githubusercontent.com", "githubassets.com", "github.io",
    "x.com", "twitter.com", "twimg.com", "t.me", "telegram.org",
    "facebook.com", "instagram.com", "whatsapp.com", "x.ai", "meta.ai",
    "llama.com", "huggingface.co", "perplexity.ai", "poe.com",
    "wikipedia.org", "wikimedia.org", "ipinfo.io", "ip.sb", "ipapi.co",
    "ipify.org",
]

RULESET_FILES = (
    "geosite-cn.srs",
    "geosite-geolocation-!cn.srs",
    "geoip-cn.srs",
)

DEFAULT_RULESET_URLS = {
    "geosite-cn.srs":
        "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
    "geosite-geolocation-!cn.srs":
        "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
    "geoip-cn.srs":
        "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
}


def bool_arg(value):
    return str(value).lower() in ("1", "true", "yes", "on")


def ruleset_urls(base):
    if not base:
        return dict(DEFAULT_RULESET_URLS)
    base = base.rstrip("/")
    return {name: f"{base}/{name}" for name in RULESET_FILES}


def render(args):
    urls = ruleset_urls(args.ruleset_base)

    proxy = {
        "type": "hysteria2",
        "tag": "proxy",
        "server": args.server,
        "server_port": int(args.port),
        "password": args.password,
        "tls": {
            "enabled": True,
            "server_name": args.sni,
            "insecure": bool_arg(args.insecure),
        },
        "up_mbps": 50,
        "down_mbps": 200,
    }
    if args.obfs_type:
        if not args.obfs_password:
            raise SystemExit("--obfs-type requires --obfs-password")
        proxy["obfs"] = {
            "type": args.obfs_type,
            "password": args.obfs_password,
        }

    return {
        "log": {"level": "warn", "timestamp": True},
        "dns": {
            "servers": [
                {
                    "tag": "dns-direct",
                    "address": "223.5.5.5",
                    "detour": "direct-out",
                },
                {
                    "tag": "dns-proxy",
                    "address": "8.8.8.8",
                    "detour": "proxy",
                },
            ],
            # Deliberately no fakeip: fake-IP plus direct CDN IPs is a common
            # source of "connected but Toutiao/WeChat times out".
            "rules": [
                {"rule_set": ["geosite-cn"], "server": "dns-direct"},
                {
                    "domain_keyword": BYTEDANCE_KEYWORDS,
                    "server": "dns-direct",
                },
                {
                    "domain_suffix": BYTEDANCE_SUFFIX,
                    "server": "dns-direct",
                },
                {
                    "rule_set": ["geosite-geolocation-!cn"],
                    "server": "dns-proxy",
                },
            ],
            "final": "dns-proxy",
            "strategy": "ipv4_only",
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 1400,
                "auto_route": True,
                "strict_route": True,
                "sniff": True,
                "sniff_override_destination": True,
            }
        ],
        "outbounds": [
            proxy,
            {"type": "direct", "tag": "direct-out"},
        ],
        "route": {
            "rule_set": [
                {
                    "tag": "geosite-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": urls["geosite-cn.srs"],
                },
                {
                    "tag": "geosite-geolocation-!cn",
                    "type": "remote",
                    "format": "binary",
                    "url": urls["geosite-geolocation-!cn.srs"],
                },
                {
                    "tag": "geoip-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": urls["geoip-cn.srs"],
                },
            ],
            "rules": [
                {"protocol": "dns", "action": "hijack-dns"},
                # The VPS has no IPv6 egress. Capturing IPv6 and rejecting it
                # is safer than letting apps bypass the tunnel on Wi-Fi.
                {"ip_version": 6, "action": "reject"},
                {
                    "domain_keyword": BYTEDANCE_KEYWORDS,
                    "outbound": "direct-out",
                },
                {
                    "domain_suffix": BYTEDANCE_SUFFIX,
                    "outbound": "direct-out",
                },
                {"rule_set": ["geosite-cn"], "outbound": "direct-out"},
                {"rule_set": ["geoip-cn"], "outbound": "direct-out"},
                {
                    "domain_suffix": CN_APP_SUFFIX + MICROSOFT_SUFFIX,
                    "outbound": "direct-out",
                },
                {"domain_keyword": CN_KEYWORDS, "outbound": "direct-out"},
                {"domain_keyword": PROXY_KEYWORDS, "outbound": "proxy"},
                {"domain_suffix": PROXY_SUFFIX, "outbound": "proxy"},
                {
                    "rule_set": ["geosite-geolocation-!cn"],
                    "outbound": "proxy",
                },
            ],
            "final": "proxy",
            "auto_detect_interface": True,
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--password", required=True)
    parser.add_argument("--sni", required=True)
    parser.add_argument("--insecure", default="1")
    parser.add_argument("--obfs-type", default="")
    parser.add_argument("--obfs-password", default="")
    parser.add_argument("--ruleset-base", default="")
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    doc = render(args)
    text = json.dumps(doc, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
