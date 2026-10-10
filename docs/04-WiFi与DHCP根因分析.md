# V50 WiFi 与 DHCP 根因分析（2026-10-10）

结论：**三个互相独立的缺陷叠加**，前两个让我连续误判方向，第三个才是 DHCP 拿不到地址的真因。

| # | 缺陷 | 表现 | 状态 |
|---|---|---|---|
| 1 | `openwrt/overlay/etc/init.d/mu300-hw` 被写成带 UTF-8 BOM | WiFi 驱动从未加载，`wlan0` 根本不存在，热点不广播 | 已修 |
| 2 | `MU300_USBNET` 补丁改了 `boot_b` 偏移 44 的内核命令行 | `switch.sh` 认不出 Linux 镜像，从 Android 切不进 Linux | 已撤 |
| 3 | **fw4 渲染出的 lan 区没有任何设备** | 客户端能关联、能发 DISCOVER，但包在进 dnsmasq 前被丢弃 | 已修 |

最终状态：`192.168.77.232/24`，网关 `192.168.77.1`，LuCI HTTP 200，经设备 DNS 可解析外网。

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

## 还没做的

- 设备上 `/etc/uci-defaults/90-mu300` 和 `opt/mu300/bin/mu300-lancheck` 还是旧版本。
  下次回 Android 时按修 `mu300-hw` 的办法（挂载 Linux 区覆盖）补上。
- `boot_b` 里的 `MU300_USBNET=rndis` 残留还在（无害，`boot/init` 只把它当环境变量读，
  LK 会从内核命令行剥掉，所以它从未生效过）。下次整机 `update` 安装会自动清掉。
- USB 侧仍未通：CDC NCM 缺 catalog 签名，RNDIS 路径上游未验证。**WiFi 已是唯一可用通道。**
