# Debian 13 IPv6 检查与修复工具

用于本文讨论的特定环境：

- Debian 13；
- `ifupdown` 使用 `/etc/network/interfaces`；
- IPv4 由 `dhcpcd` 获取；
- IPv6 配置为 `inet6 auto` 或 `inet6 static`；
- 服务商只允许正式分配的 EUI-64 IPv6，`dhcpcd` 的 `slaac private` 地址无法出站。

服务商控制台显示的每台 VPS IPv6 都不同。脚本不会内置、推导或写入任何示例 IPv6；需要修复以及重启后完成验证时，用户都必须输入当前 VPS 控制台中的地址。

## 使用

真正的一行启动命令（启动器会下载并校验主脚本）：

```bash
bash <(curl -fsSL https://github.com/elonjack/debian13-ipv6-repair/releases/latest/download/install.sh)
```

这是一行命令，但依然属于“下载远程启动器并执行”。希望在执行前先查看全部文件时，请使用下面的手动校验流程。

从最新 Release 下载并校验后运行：

```bash
curl -fL -o debian13-ipv6-repair.sh \
  https://github.com/elonjack/debian13-ipv6-repair/releases/latest/download/debian13-ipv6-repair.sh
curl -fL -o SHA256SUMS \
  https://github.com/elonjack/debian13-ipv6-repair/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS
chmod +x debian13-ipv6-repair.sh
sudo ./debian13-ipv6-repair.sh
```

也可以克隆仓库后运行：

```bash
chmod +x debian13-ipv6-repair.sh
sudo ./debian13-ipv6-repair.sh
```

选择：

```text
1) 检查并按需修复 IPv6
```

交互式菜单在支持颜色的终端中使用黄色显示；设置 `NO_COLOR=1` 可关闭颜色。脚本拒绝无 TTY/管道方式执行，避免提示输入缺失时误操作。

脚本会先完成只读检查，包括：

- 自动识别默认出口网卡；
- 识别 `inet6 auto`/`inet6 static`；
- 列出全部全局 IPv6 和默认路由；
- 检查系统实际选择的源地址；
- 将默认路由源地址和公网回显地址与控制台 IPv6 精确比较；
- 分别绑定每个 IPv6 测试公网出口；
- 检查 `dhcpcd` 是否仍处理 RA/SLAAC；
- 检查当前内核 RA、SLAAC、临时地址和地址生成模式。

ifupdown 的 IPv6 方法不只有 `auto/static`，还包括 `manual`、`dhcp`、`v4tunnel`、`6to4` 和 `loopback` 等。本工具会识别并报告这些模式，但只对已经验证的 `auto/static` 执行自动修复，其他模式零修改退出。

只有在发现已确认的配置冲突时才会询问是否修复。健康状态下不会创建文件、改配置或重启服务。

若检测到问题但需要修复，服务商控制台 IPv6 为必填项。脚本还会确认：

- 地址语法可识别；
- 输入地址精确存在于当前出口网卡，而不是只匹配同一 `/64` 前缀；
- 静态模式下，输入地址与现有 static address 语义一致；
- 自动模式下，输入地址既是内核 RA 地址，也是由当前网卡 MAC 生成的 EUI-64；
- 恰好只有一个 inet6 stanza；
- dhcpcd 正在运行；
- NetworkManager/systemd-networkd 未同时接管网卡。

任一条件不满足时只报告，不修改。检测到会在启动时覆盖修复结果的显式 `accept_ra`、`autoconf` 或 `privext` 选项时也会拒绝修改。

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
- 不在线加载新写入的 sysctl 参数，所有网络变更统一在用户确认重启后生效；
- 修改前备份到 `/var/backups/debian13-ipv6-repair/`；
- 所有写入均可重复执行，不会重复追加管理块；
- 首次运行只写入修复配置，并明确标记“等待重启验证”；
- 重启后再次运行选项 1，并再次输入同一控制台 IPv6；只有网络检查和地址归属核验均通过才报告修复成功；
- 留空只检查网络可用性，不能进入修复，也不能清除待验证标记；
- 无法识别的网络管理方式不会自动修改。
- 不会添加、替换或写死服务商 IPv6/网关；只处理 dhcpcd RA 冲突和模式对应的内核参数。

## 为什么需要重启后再次验证

`dhcpcd` 同时承担 IPv4 DHCP。在线终止或重启它可能让当前 SSH 连接断开。因此脚本只安全写入配置，由用户确认后重启 VPS。重启后再次执行检查，才能证明错误地址和重复路由没有重新出现。

## 地址归属保证

- `inet6 static`：脚本要求控制台输入地址、`inet6 static` 的 `address` 和网卡当前精确地址三者一致；修复过程中不改写该地址或网关。
- `inet6 auto`：除要求控制台输入地址是当前 `proto kernel_ra` 地址外，还会根据当前网卡 MAC 计算 EUI-64 并精确比对。只有比对成功才允许写入 `addr_gen_mode=0`。
- 如果服务商分配方式不是上述两种之一，或控制台地址当前不在网卡上，脚本只报告并退出，不会猜测地址。

