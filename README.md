# Debian 13 IPv6 检查与修复工具

用于本文讨论的特定环境：

- Debian 13；
- `ifupdown` 使用 `/etc/network/interfaces`；
- IPv4 由 `dhcpcd` 获取；
- IPv6 配置为 `inet6 auto` 或 `inet6 static`；
- 服务商只允许正式分配的 EUI-64 IPv6，`dhcpcd` 的 `slaac private` 地址无法出站。

服务商控制台显示的每台 VPS IPv6 都不同。脚本不会内置、推导或写入任何示例 IPv6；需要修复时，用户必须输入当前 VPS 控制台中的地址，脚本仅用它核对现有配置。

## 使用

```bash
chmod +x debian13-ipv6-repair.sh
sudo ./debian13-ipv6-repair.sh
```

选择：

```text
1) 检查并按需修复 IPv6
```

脚本会先完成只读检查，包括：

- 自动识别默认出口网卡；
- 识别 `inet6 auto`/`inet6 static`；
- 列出全部全局 IPv6 和默认路由；
- 检查系统实际选择的源地址；
- 分别绑定每个 IPv6 测试公网出口；
- 检查 `dhcpcd` 是否仍处理 RA/SLAAC；
- 检查当前内核 RA、SLAAC、临时地址和地址生成模式。

ifupdown 的 IPv6 方法不只有 `auto/static`，还包括 `manual`、`dhcp`、`v4tunnel`、`6to4` 和 `loopback` 等。本工具会识别并报告这些模式，但只对已经验证的 `auto/static` 执行自动修复，其他模式零修改退出。

只有在发现已确认的配置冲突时才会询问是否修复。健康状态下不会创建文件、改配置或重启服务。

若检测到问题但需要修复，服务商控制台 IPv6 为必填项。脚本还会确认：

- 地址语法可识别；
- 静态模式下，输入地址与现有 static address 一致；
- 自动模式下，输入地址确实是网卡上的内核 RA 地址；
- 恰好只有一个 inet6 stanza；
- dhcpcd 正在运行；
- NetworkManager/systemd-networkd 未同时接管网卡。

任一条件不满足时只报告，不修改。

## 修复策略

两种模式都会为对应网卡向 `/etc/dhcpcd.conf` 添加：

```text
interface ens3
noipv6rs
```

### `inet6 auto`

- 保留 ifupdown/内核 RA；
- 使用 MAC 派生的 EUI-64；
- 禁止临时地址；
- dhcpcd 不再创建 `slaac private` 地址和第二条 RA 路由。

### `inet6 static`

- 保留服务商写入的静态 IPv6 和网关；
- 关闭该网卡的内核 RA/SLAAC；
- dhcpcd 不再创建动态隐私地址和 RA 路由。

## 安全设计

- 不自动安装依赖；
- 不在线执行 `ifdown`、重启 networking 或终止 dhcpcd；
- 修改前备份到 `/var/backups/debian13-ipv6-repair/`；
- 所有写入均可重复执行，不会重复追加管理块；
- 首次运行只写入修复配置，并明确标记“等待重启验证”；
- 重启后再次运行选项 1，只有所有检查通过才报告修复成功；
- 无法识别的网络管理方式不会自动修改。
- 不会添加、替换或写死服务商 IPv6/网关；只处理 dhcpcd RA 冲突和模式对应的内核参数。

## 为什么需要重启后再次验证

`dhcpcd` 同时承担 IPv4 DHCP。在线终止或重启它可能让当前 SSH 连接断开。因此脚本只安全写入配置，由用户确认后重启 VPS。重启后再次执行检查，才能证明错误地址和重复路由没有重新出现。

