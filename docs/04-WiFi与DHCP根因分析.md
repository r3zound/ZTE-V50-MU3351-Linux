# V50 WiFi、DHCP 与转发根因分析（2026-10-10）

结论：**四个互相独立的缺陷**。前两个让我连续误判方向，第三个是 DHCP 拿不到地址的真因，
第四个表现为「没有 DNS / 上不了网」，但**根本不是 DNS 问题**。

| # | 缺陷 | 表现 | 状态 |
|---|---|---|---|
| 1 | `openwrt/overlay/etc/init.d/mu300-hw` 被写成带 UTF-8 BOM | WiFi 驱动从未加载，`wlan0` 根本不存在，热点不广播 | 已修 |
| 2 | `MU300_USBNET` 补丁改了 `boot_b` 偏移 44 的内核命令行 | `switch.sh` 认不出 Linux 镜像，从 Android 切不进 Linux | 已撤 |
| 3 | **fw4 渲染出的 lan 区没有任何设备** | 客户端能关联、能发 DISCOVER，但包在进 dnsmasq 前被丢弃 | 已修 |
| 4 | **`accept_to_wan` 为空 + flow offload 挡住防火墙重载** | 经本机的**转发 TCP 全部被 RST**，但本机 DNS 与 ICMP 正常 → 像「没有 DNS」 | 已修 |

最终状态：`192.168.77.232/24`，网关 `192.168.77.1`，LuCI HTTP 200，经设备 DNS 可解析外网。
**补齐后**：经 WiFi 与 USB RNDIS 的真实 HTTPS 均返回 200（0.35s / 0.18s）。

---

## 缺陷 1：mu300-hw 带 UTF-8 BOM，init 脚本静默失败

### 证据

设备上直读（挂载 Linux 区）：

```
ef bb bf 23 21 2f   /etc/init.d/mu300-hw     ← BOM + #!/
23 21 2f 62 69 6e   /etc/init.d/mu300-post    ← 干净
23 21 2f 62 69 6e   /opt/mu300/bin/mu300-lancheck
```

启动日志对比（同一份 persist log 工具，`< 10.8.9` 为首次启动）：

| 标记 | 首次启动 | 本次启动 |
|---|---|---|
| `wlan0` | 326 次 | **1 次** |
| `sc2355` | 221 次 | **0** |
| `marlin` | 110 次 | 2 |
| `wcn` | 28 次 | **0** |
| `entered forwarding` | 4 次 | **0** |

首次启动 20.8s 处有：

```
[   20.837321] [T6084] calling init_module ... [wcn_bsp]
[   21.023383] [T6129] calling init_module ... [sprd_wlan_combo]
```

本次启动完全没有——`/etc/init.d/mu300-hw` 里 `bringup_step 90 wifi-start ...` 从未执行，
`/tmp/mu300-hw.log`、`mu300-wifi-start.log`、`mu300-extra-modules.log` 三个文件全部不存在。

### 为什么会这样

上游 `git show HEAD:openwrt/overlay/etc/init.d/mu300-hw` 在仓库里就是 **UTF-16LE + CRLF**：

```
head = FF FE 23 00 21 00 2F 00      # UTF-16LE BOM + "#!/" 宽字符
```

`[IO.File]::ReadAllText` 能正确解码，`WriteAllText` 也写成正常 UTF-8——但某一步留下了 BOM。
BOM 使内核无法解析 shebang，busybox init **静默跳过**该脚本：控制台没有任何错误，日志里也查不到。

首启之所以正常，是因为装的是预编译 release 的 rootfs（那份 `mu300-hw` 是好的），
而 `openwrt/overlay/` 只在从源码构建时才读——这正是之前发现的那条。
我的 vendor 覆盖包把 overlay 里这份**坏的**盖到了好的上面。

### 修法

- 去掉两份副本的 BOM，统一 UTF-8 + LF。
- `tools/apply-v50-patches.ps1` 的 `Patch()` 显式用 `UTF8Encoding($false)` 写出。
- 新增**第 11 步硬门禁**：扫描所有要上设备的目录
  （`openwrt/vendor-extra`、`openwrt/overlay`、`rootfs/overlay`、`boot`），
  出现 UTF-16 / BOM / CRLF 直接 `throw`。独立脚本 `tools/audit-repo-encoding.ps1`。

---

## 缺陷 2：MU300_USBNET 补丁让 Android 侧认不出 Linux

### 证据

```
$ su -c 'sh switch.sh status'
boot_b   a boot image that is not Linux (the Android from before an update?)
```

`boot_b` 偏移 44：

```
6c 6f 67 6c 65 76 65 6c 3d 35 20 4d  →  "loglevel=5 MU300_USBNET=rndis"
```

而 `switch.sh:76` 认的是 11 字节 `loglevel=5\0`（`LINUX_CMDLINE=6c6f...3500`）。
第 11 字节从 `00` 变成 `20`，`refuse to arm`，于是**从 Android 切不进 Linux**，报错还指错了方向。

### 为什么撤掉而不是修 switch.sh

RNDIS 本来就无效——设备依旧枚举成 CDC NCM（上游 `docs/FINDINGS.md` 也标注该路径
"not measured, no Windows host"）。它没带来任何好处，只带来了这个副作用，所以整条撤掉。

同时把 `switch.sh` 的识别改成只比前 10 字节（`6c6f676c6576656c3d35`），
将来再有人往命令行尾部追加东西，也不会再把装好的 Linux 藏起来。

---

## 缺陷 3：fw4 渲染出的 lan 区是空的（DHCP 真因）

### 这才是 DHCP 拿不到地址的原因

先排除干扰项。设备上实测：

- `iw dev wlan0 station dump` → `Station <PC网卡MAC> (on wlan0)`，PC 已关联
- `/proc/net/dev` → wlan0 RX 3701 包，errs/drop 全 0，**帧确实到达**
- `netstat -ulnp` → `0.0.0.0:67` 由 dnsmasq(13929) 监听
- `/var/etc/dnsmasq.conf.cfg01411c` → `dhcp-range=set:lan,192.168.77.100,192.168.77.249,...`
- dnsmasq 前台 `--log-dhcp` 启动时打印 `DHCP, IP range 192.168.77.100 -- 192.168.77.249`
- **但一条 `DHCPDISCOVER` 都没出现**

包到了设备，dnsmasq 却没收到 → 中间有人丢了。看 nftables：

```
$ nft list chain inet fw4 input
chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state vmap { established : accept, related : accept }
    tcp flags & (fin|syn|rst|ack) == syn jump syn_flood
    iifname { "usb0", "rndis0" } jump input_earlyusb
    jump handle_reject
}

$ nft list chain inet fw4 accept_from_lan
chain accept_from_lan {
}

$ nft list ruleset | grep -c br-lan
0
```

**`input` 链里根本没有 `iifname "br-lan" jump input_lan`**，策略是 `policy drop`。
从网桥（含 WiFi）进来的一切被丢弃：DHCP、DNS、LuCI、SSH 全都不通。

而 `/etc/config/firewall` 里明明写着：

```
firewall.cfg02dc81.name='lan'
firewall.cfg02dc81.network='lan'
firewall.cfg02dc81.input='ACCEPT'
```

**UCI 说 ACCEPT，渲染出的规则集里却没有任何东西属于 lan 区**——这就是我前几轮判断失误的地方：
只读配置文件会得出"防火墙没问题"的错误结论。

### 成因

fw4 从网络的**网桥端口**推导某个区包含哪些接口。而 `br-lan` 是这样声明的：

```
network.@device[0].name='br-lan'
network.@device[0].type='bridge'
network.@device[0].bridge_empty='1'
```

`bridge_empty=1`（有线 LAN 不该等一个还不存在的成员），`wlan0` 是 netifd 后来拉起 AP 时才加进网桥的。
等 fw4 渲染规则集那一刻，lan 区一个设备都没有——网桥本身从没被算进去。

### 修法

在 `90-mu300`（每次安装/更新都跑）里把网桥本体写进 lan 区：

```sh
lan_dev=$(uci -q get network.lan.device)
if [ -n "$lan_dev" ]; then
	for z in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='lan'$/\1/p"); do
		uci -q get "firewall.$z.device" | grep -qx "$lan_dev" || uci add_list "firewall.$z.device=$lan_dev"
	done
fi
```

设备上验证：

```
$ uci add_list firewall.cfg02dc81.device='br-lan'; /etc/init.d/firewall stop; /etc/init.d/firewall start
$ nft list chain inet fw4 accept_from_lan
chain accept_from_lan {
    iifname "br-lan" counter packets 0 bytes 0 accept
}
```

注意 `firewall restart` 会失败（`flowtable ft` → `Resource busy`），必须 `stop` 再 `start`。

之后 PC 立刻拿到 `192.168.77.232`。

---

## 缺陷 4：转发 TCP 全被 RST —— 最不像防火墙的防火墙问题

### 症状

用户报「OpenWrt 貌似没有 DNS，不能上网」。实测：

```
nft list chain inet fw4 accept_to_wan
table inet fw4 {
	chain accept_to_wan {
	}
}
```

**空的。** 于是 `forward` 链的走向是：

```
chain forward { policy drop;
    iifname "br-lan" jump forward_lan   →  jump accept_to_wan（空，穿过）
                                        →  jump accept_to_lan（oifname br-lan，不匹配）
    jump handle_reject                  →  meta l4proto tcp reject with tcp reset
}
```

**每一个转发的 TCP 连接都被 RST**。实测（强制源地址，绕开本地代理）：

| 源地址 | 目标 :443 | 结果 |
|---|---|---|
| 有线 172.20.4.180（对照） | 百度 | ✅ 40ms |
| WiFi 192.168.77.232（经本机） | 百度 | ❌ 拒绝/RST |
| RNDIS 192.168.77.247（经本机） | 百度 | ❌ 拒绝/RST |

而**本机自己**解析域名正常、`ping 223.5.5.5` 正常、能上外网 —— 所以看起来像「DNS 坏了」。

### 成因链（三步，每步都"看起来正常"）

1. **WAN 的 `l3_device` 出现得比 fw4 渲染晚。**
   `network.wan.proto='mu300cell'` 是本项目自定义的 netifd proto，`l3_device` 要等 modem 拨号成功才是 `sipa_eth0`。
   而 fw4 是从**接口的设备**推导 zone 规则的，开机那次渲染时 wan 区解析不到设备 → `accept_to_wan` 生成为空。

2. **OpenWrt 本来有修复机制，但它恰好失效。**
   `/etc/hotplug.d/iface/20-firewall` 会在 wan ifup 时执行 `fw4 -q reload`：

   ```sh
   [ "$ACTION" = ifup -o "$ACTION" = ifupdate ] || exit 0
   has_zone || exit 0
   logger -t firewall "Reloading firewall due to $ACTION of $INTERFACE ($DEVICE)"
   fw4 -q reload
   ```

3. **`fw4 -q reload` 静默失败，因为 flow offload 开着。**
   `flow_offloading='1'` 会建一个 `flowtable ft`；表里有活跃流时无法重建，nft 直接中止整个事务：

   ```
   /dev/stdin:10:12-13: Error: Could not process rule: Resource busy
   	flowtable ft {
   ```

   而 **`-q` 把这个错误吞掉了** —— 日志里连一行都没有。从 shell 手动跑 `fw4 reload` 或
   `/etc/init.d/firewall reload` 也是同样失败，**只有 `stop` + `start` 能成功**。

结果：`accept_to_wan` 永远是空的，而且**永远不会自愈**。

### 修法

把 flow offload 关掉即可 —— 没有 flowtable，`fw4 -q reload` 就能成功，于是第 2 步那个
**已有的**热插拔钩子会在每次 WAN 起来时自动修好：

```sh
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall
/etc/init.d/firewall stop; sleep 2; /etc/init.d/firewall start
```

**不需要新增任何脚本** —— 这是这个 bug 最值得记的一点：修复机制一直都在，只是被 offload 挡住了。

实测验证（关闭 offload 后，手动触发 wan 的 ifup 钩子）：

```
logread → user.notice firewall: Reloading firewall due to ifup of wan ()
nft list chain inet fw4 accept_to_wan
	oifname "sipa_eth0" ct state invalid counter packets 0 bytes 0 drop comment "!fw4: Prevent NAT leakage"
	oifname "sipa_eth0" counter packets 6 bytes 1092 accept comment "!fw4: accept wan IPv4/IPv6 traffic"
```

之后真实 HTTPS 经 WiFi 与 RNDIS 均返回 **200**。

补丁脚本第 12 步把 `90-mu300` 里的 `flow_offloading` 从 `'1'` 改成 `'0'` 并写明原因，
否则**新装的设备会重新打开 offload，再踩一遍**。

代价：转发的 TCP/UDP 不再走软件快速转发。但 SIPA 与 SC2355 本来就没有硬件 offload，
而「防火墙再也无法重载」比「没有 flow offload」严重得多。

### 为什么容易被误判成 DNS

- 设备自己的 DNS（`nslookup ... 127.0.0.1`）正常 → 以为 DNS 没问题
- 设备自己 `ping 223.5.5.5` 正常 → 以为出口没问题
- 客户端**能拿到 IP**、能 ping 通网关 → 以为链路没问题
- 真正坏的只有「**转发**」这一层，而 `accept_to_wan` 是**渲染后**的结果 ——
  只看 `/etc/config/firewall` 会看到 `masq='1'`、`network='wan'`，一切正常

**判据**：客户端用本机做 DNS 能解析、但访问任何网站都失败时，直接看这个：

```sh
nft list chain inet fw4 accept_to_wan     # 空 = 命中此问题
ip route | grep -c 192.168.77             # 1 = 路由正常（排除缺陷 3/5）
```

---

## 缺陷 5：rndis0 加入网桥后仍持有 LAN 地址（重复路由）

见下节「我自己写的 mu300-lancheck 有两个 bug」之后的内容 —— 简言之：
`10-mu300-usb` 的地址清理循环只处理「已经是 br-lan 端口」的网卡，
而 `rndis0` 是在**之后**才加入网桥的，于是它同时持有 `192.168.77.1/24`，
产生两条相同的 `192.168.77.0/24` 路由，回包走 USB → WiFi 客户端连 ping 都不通。
修法是在把 `rndis0` 加入网桥**之后**再跑一次同样的地址清理（补丁脚本第 11 步），已实测：
人为造出故障 → 触发 `ifup lan` → 地址被自动清掉、路由只剩一条。

---

## 我自己写的 mu300-lancheck 有两个 bug

第一次读它就把我带偏了：

1. **67 端口是 UDP，脚本去 `/proc/net/tcp` 里找** —— 永远只能得出"没人监听"，
   哪怕 dnsmasq 好好的。已改为 `/proc/net/udp`。
2. **配置名 glob 写成 `/var/etc/dnsmasq.conf.*`** —— netifd 生成的文件名带哈希后缀
   （`dnsmasq.conf.cfg01411c`），19.9s 那个时刻还没生成，所以 `range=[]`。已改为不带后缀。

同时新增 `fw-jump=` 一行，直接读**渲染后的规则集**而不是配置，专门盯住缺陷 3 那一类问题。

---

## 调试通道：COM12 的 USB ACM 控制台

本次全程靠它拿到 root shell，是唯一没被防火墙影响的入口：

```
$ powershell -File tools\mu300-console.ps1 -ReadSeconds 25 -Commands @('cmd1','cmd2')
```

OpenWrt 25.12 的 `/etc/inittab` 里有 `ttyGS0::askfirst:/usr/libexec/login.sh`，直接给 root 提示符。

两个坑：
- **不要让 dnsmasq 前台跑**（`-d`），它会占住控制台，关掉端口后 shell 就失联了，要 Ctrl+C 才能拿回来。
- netifd 会不停重启 dnsmasq，手工 `killall` + 手工启动的实例常被顶掉，日志文件会莫名其妙是空的。

---

## 登录

- **WiFi**：SSID `<你的热点名>`，密码 `<你的热点密码>`（安装时从 Android 热点导入）
- **LuCI**：`http://192.168.77.1/cgi-bin/luci/`（**路径末尾的斜杠必须有**，少了会 403），root / `<你的root密码>`
- **SSH**：`ssh root@192.168.77.1`

### 密码这条走过弯路（2026-10-10）

第一次安装跑的是 `update` 模式。安装器在 update 模式下**故意不设置密码**
（`mu300-install.sh` 的 `KEEP_PW`：update 保留已有系统的账号和密码）。
所以答案文件里填的 `<你的root密码>` 根本没被采用，设备上真实的密码来自首次安装/
release 镜像，记录在 Android 的 `/data/adb/mu300-linux-password.txt`——而 `/data`
在 Linux 根文件系统里根本不存在。

用设备上的 salt 重算 SHA-512 才确认它不是 `<你的root密码>`（别信"我填过所以就是它"），
随后在串口 root shell 里把它重设成 `<你的root密码>`，原文件备份在设备 `/etc/shadow.bak`。

两个踩坑点：
- LuCI 的 GET 返回 **403 + `X-Luci-Login-Required: yes`** 是正常的"未登录"表现，
  不是登录坏了；GET 时也不会下发 `sysauth` cookie。
- 判断密码对错只能看 POST 后有没有 `Set-Cookie: sysauth_http=...` 和 302。

---

## 附：LuCI 端口状态里的幽灵 `eth0`

**症状**：`http://192.168.77.1/cgi-bin/luci/admin/status/overview` 的「端口状态」里有一个
`eth0` 永远显示**未连接**，而这台设备上根本没有 `eth0`。

**真因**：`/etc/board.json` 里写着

```json
"network": { "lan": { "device": "eth0", "protocol": "static" } }
```

这是 **armsr/armv8 通用目标**的基础镜像假设（`/etc/board.d/02_network` 与 `99-default_network`
写死的），而 V50 的 LAN 是一个只承载 USB gadget 与 AP 的网桥 `br-lan`。

LuCI 的端口状态页读的正是这个字段：

```
luci getBuiltinEthernetPorts  →  [{"role":"lan","device":"eth0"}]
```

（实现：`/www/luci-static/resources/view/status/include/29_ports.js` 调
`luci.getBuiltinEthernetPorts`，后者读 `board.json`。）

**为什么不会被自动修好**：`board.json` 只在**镜像构建时**由 `config_generate` 生成一次，
所以这个过期的值能活过每一次安装和每一次更新 —— 没有任何机制会去纠正它。

**修法**：UCI 那边本来就是对的（`network.lan.device='br-lan'`），把它抄过去即可。
已写进 `90-mu300`（补丁脚本第 13 步）：

```sh
mu300_board_dev=$(uci -q get network.lan.device)
if [ -n "$mu300_board_dev" ] && [ -f /etc/board.json ]; then
	sed -i "s/\"device\": \"eth0\"/\"device\": \"$mu300_board_dev\"/" /etc/board.json 2>/dev/null || true
fi
```

实测（造故障 → 修好 → 再跑一次确认幂等）：

```
1. sed 改回 eth0            → "device": "eth0"
2. 执行上面那段              → "device": "br-lan"
3. 再执行一次                → "device": "br-lan"（幂等）
luci getBuiltinEthernetPorts → [{"role":"lan","device":"br-lan"}]   （up、carrier: true）
```

> 顺带说明：这台设备**确实没有任何以太网口**，所以端口状态一栏本身意义有限；
> 但显示一个不存在的端口并标成"未连接"是明确的错误信息，会让人以为硬件有问题。

---

## 附：状态看板把「USB 网络」显示成「未连接」

**症状**：`http://192.168.77.1/cgi-bin/luci/admin/home` 的状态看板里，**USB 网络显示「未连接」**，
而 USB 链路明明是通的（PC 正通过它收发数据）。

**真因**：又是同一个根因家族 —— **代码写死 `usb0`，而 RNDIS 模式下 gadget 网卡叫 `rndis0`**。

前端那行（`view/mu300/home.js`）：

```js
M.set('wusb', (i.net && i.net.usb0 && i.net.usb0.up) ? _('Connected') : _('Disconnected'));
```

后端 `/usr/libexec/unisoc-modem/dashboard-info`：

```sh
USB_DEVICE=$(safe_iface "$(cfg usb_device)" usb0)     # ← 回落值是字面量 usb0
...
printf '"net":{...,"usb0":%s},' ... "$(net_obj "$USB_DEVICE")"
```

`net_obj` 在设备不存在时返回 `null`：

```sh
net_obj() { local d=/sys/class/net/$1; [ -d "$d" ] || { echo null; return; } ... }
```

而 `usb_device` 在 mu300 的 UCI 配置里**从未设置**，于是永远取字面量 `usb0`：

```
$ ls /sys/class/net/     →  ... rndis0 ...            （没有 usb0）
$ ls /sys/class/net/br-lan/brif →  rndis0  wlan0
$ uci show mu300 | grep usb_device →  （空）
```

→ `net.usb0` 恒为 `null` → 看板永远显示「未连接」。

**修法**（补丁脚本第 14 步）：设备名按实际存在的那个来，JSON 键仍是 `usb0`（前端读的是这个键）。

```sh
if [ ! -d "/sys/class/net/$USB_DEVICE" ]; then
	for _c in usb0 rndis0; do
		[ -d "/sys/class/net/$_c" ] && { USB_DEVICE=$_c; break; }
	done
fi
```

实测：修前 `"usb0":null` → 修后 `"usb0":{"rx":5914580530,"tx":6766551764,"up":1}`。

> 该文件不在 `openwrt/overlay/` 下（它属于 `openwrt/luci-app-mu300/root/`），
> 所以补丁脚本的镜像步骤给它加了 `目标路径=源路径` 的写法，才能进 vendor-extra 通道送到设备。

---

## 附：邻区表全部为空 —— 这个不是 bug

**症状**：状态看板的「邻区」表格「制式/频段/PCI/频点/RSRP/RSRQ/SINR」**全部为空**，
显示「暂无邻区数据」。

**结论：看板是如实反映，调制解调器就是返回 0 个邻区。** 手工执行脚本用的那两条 AT 指令验证：

| AT 指令 | 用途 | 实测返回 |
|---|---|---|
| `AT+SPQ5GNCELLEX` | NR 邻区表 | `427010,308,-7457,-575,2095,0,0,0,0,` |
| `AT+SPENGMD=0,6,6` | LTE 邻区槽位 | `0,0,0,...` ×8 组 |
| `AT+SPENGMD=0,14,1` | NR **服务**小区 | 完整数据（band1 / ARFCN 427010 / PCI 308 / RSRP −74.8 / SINR 21.2） |

`AT+SPQ5GNCELLEX` 的第 9 个字段就是**邻区数量**，这里是 **`0`**；解码函数也读这个字段：

```awk
BEGIN { m = split(line, a, ","); cnt = a[9]+0; ... for (i = 0; i < cnt ...) }
```

`cnt=0` → 解出空列表 → `"neigh":null` → 看板显示「暂无邻区数据」。

**判据**：**服务小区数据正常、只有邻区为空** → 不是看板问题。
若连服务小区也空，那才要去查 `MODE=full` 与注册状态（脚本用 `REGISTERED` 门槛跳过无服务时的
AT 连锁超时）。

**为什么调制解调器不给邻区**（未进一步定论，属固件/网络侧行为）：两条查询都在已注册状态下执行，
但都返回空。`AT+SPENGMD=0,6,6` 要求 LTE 有服务小区（当前是 NR SA），所以为全 0 属正常；
NR 邻区为 0 则更像该模块在当前网络/模式下不做邻区上报。
**注意**：脚本注释里明确警告 `AT+SPENGMD=0,1,0` 会把 AT 口切到流模式，**不要乱试**未文档化的工程模式命令。

---

## 还没做的

- 设备上 `/etc/uci-defaults/90-mu300` 和 `opt/mu300/bin/mu300-lancheck` 还是旧版本。
  下次回 Android 时按修 `mu300-hw` 的办法（挂载 Linux 区覆盖）补上。
- `boot_b` 里的 `MU300_USBNET=rndis` 残留还在（无害，`boot/init` 只把它当环境变量读，
  LK 会从内核命令行剥掉，所以它从未生效过）。下次整机 `update` 安装会自动清掉。
- USB 侧仍未通：CDC NCM 缺 catalog 签名，RNDIS 路径上游未验证。**WiFi 已是唯一可用通道。**
