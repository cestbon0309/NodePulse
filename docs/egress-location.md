# Egress IP and location / 出口 IP 与位置

Full probes discover their public egress IP at startup and about every six hours.
DNS and the small HTTP request run in a bounded helper process; the existing
event loop checks a nonblocking pipe, so discovery does not block sampling or
monitoring. Failed providers are tried in order, followed by exponential retry
backoff (60 seconds to one hour). The last successful address is retained on
failure. Pure relay servers and temporary pairing do not perform discovery.
Default lite builds omit discovery to preserve the 200,000-byte budget.

完整版启动时及约每六小时查询一次出口公网 IP。DNS/HTTP 在有超时的辅助进程中执行，
主事件循环非阻塞读取结果，不影响采样。失败时轮换服务，再以 60 秒至一小时退避重试；
保留上次成功结果。纯中继和临时配对不查询。默认 lite 为保持体积预算不包含此功能。

```ini
# Optional configuration; CLI -E overrides this field.
# 可选配置；命令行 -E 优先。
egress_service=http://api.ipify.org,http://ifconfig.me/ip,http://icanhazip.com
# Disable / 关闭:
# egress_service=off
```

Only syntactically valid public IPv4/IPv6 results are included as `egress_ip` in
snapshots. HTTP discovery is deliberately **unauthenticated**: the provider and
network observers see the node address and can misreport it. It is display-only
metadata, never a trusted pairing address, identity or authorization input.
The installer’s independently confirmed public address is unchanged.

只接受有效的公网 IPv4/IPv6，并以 `egress_ip` 加入快照。HTTP 查询**不验证服务端身份**，
服务商及网络观察者可获知地址或篡改结果；仅作位置展示，不用于配对、身份或授权。
不改变安装器单独确认的公网连接地址。

The iOS app looks up public addresses via HTTPS at **ipwho.is**, using the app’s
system-selected Chinese or English language. This shares the egress IP with
that provider, but not secrets or interface addresses. Results are persisted
per IP/language for seven days (failed lookups for 15 minutes), capped at 512
entries. Location is approximate: normally country-region, country-city when
the region is absent, and country-city in Australia (e.g. Australia-Sydney).
Duplicate city-state names are shown once. Missing/failed lookups do not prevent
monitoring. Demo locations are offline fixtures, not live geolocation claims.

iOS 经 HTTPS 向 **ipwho.is** 查询，跟随系统选择中文/英文；仅发送出口 IP，不发送密钥或
内网接口地址。按 IP+语言持久缓存七天（失败缓存 15 分钟），最多 512 项。位置仅供参考：
通常显示国家-地区，无地区或澳大利亚显示国家-城市（如 Australia-Sydney），城邦不重复。
失败不影响监控。演示模式使用离线位置示例。

The eye toggle hides **all** IPs using the fixed `•.•.•.•` mask, regardless of
address length/family, while retaining location labels. Copy still copies the
real address. Hiding is presentation-only and does not disable geolocation;
disable probe discovery to avoid automatic lookups for that node.

眼睛开关以固定 `•.•.•.•` 隐藏全部 IP，不泄露长度或地址族；位置仍显示，复制仍为真实地址。
隐藏仅影响展示，不关闭位置查询；不希望该节点自动查询时，请关闭探针出口发现。
