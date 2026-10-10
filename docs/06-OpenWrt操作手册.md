# V50 / mu300-linux 操作手册

设备：ZTE V50（`MU3351`），Android 13 + OpenWrt 25.12.5 双系统，跑在 `dikeckaan/mu300-linux` 上。

本文所有命令都是**2026-10-10 实测**通过的；未验证的会明确标注。

---

## 0. 通道总览

| # | 通道 | 前提 | 能力 | 可靠性 |
|---|---|---|---|---|
| 1 | **WiFi + SSH** | 已在 OpenWrt 且 WiFi 正常 | 完整 root shell，日常首选 | ★★★★★ |
| 2 | **WiFi + LuCI** | 同上 | 网页管理、图形化改配置 | ★★★★★ |
| 3 | **WiFi + JSON-RPC** | 同上 | 脚本化调 ubus（含 mu300 专有 API） | ★★★★☆ |
| 4 | **USB 串口 COM12** | 已在 OpenWrt | root shell，**不受网络/防火墙影响** | ★★★★★（救命通道） |
| 5 | **USB 网络 (RNDIS)** | 已在 OpenWrt | 第二网口，192.168.77.247 | ★★★☆☆（与 WiFi 冲突） |
| 6 | **adb (USB)** | 在 **Android** | Android shell + Magisk root | ★★★★★（切系统用） |
| 7 | **离线挂载 Linux 分区** | 在 Android | 直接改 OpenWrt 的文件（网络全坏时用） | ★★★★☆ |
| 8 | **BROM 短接 + WPFlasher** | 设备变砖 | 刷回备份分区 | ★★☆☆☆（保底，未在本文复测） |
| 9 | **adb 无线 (5555)** | 在 Android | 同 6，无需插线 | ★★★☆☆ |

**首选组合**：平时用 1；网络出问题用 4；要在两个系统间切换用 6。

---

## 1. 系统切换

### 1.1 为什么「在 OpenWrt 里点重启」会回到 Android

**这是设计如此，不是故障。** 源码 `android/magisk/mu300-linux-switch/switch.sh` 开头写得很清楚：

> LK then boots Linux once. Linux writes Android's block back as one of its first steps, so the reboot
> after that returns to Android, and a Linux that does not boot falls back to Android by itself.

也就是说 **Linux 每次都是一次性试用**：进 Linux 后它自己就把 boot 控制块改回 Android，所以之后任何重启都回 Android。想再进 Linux，必须**从 Android 侧再切一次**。

安全边界（`switch.sh` 只写这些）：
- 只改 `misc` 分区偏移 `0x800` 的 **32 字节** AOSP `bootloader_control`（含重算的 CRC32）
- `boot_a`、GPT、`userdata` **完全不碰**
- Linux 起不来 → 自动回 Android

### 1.2 从 Android 切到 OpenWrt（四种方式）

**方式 A — 设备本机终端（最快，无需电脑）**

装了终端 App 的话：

```sh
su -c mu300-linux
```

**方式 B — Magisk 面板（点一下）**

Magisk App → 模块 → **MU300 Linux switch** → 点 **操作 / Action** 按钮。

> ⚠️ 这个按钮**只在模块被启用时才出现**。2026-10-10 发现设备上多了一个 `disable` 文件（仓库里的 `customize.sh` 并不创建它），导致模块被 Magisk 视为停用，于是 `mu300-linux` 也不在 PATH 上。已用**改名**方式修好（可逆，`/data/adb/modules/mu300_linux_switch/disable.off`）。
> 若哪天又不见了：`mv disable disable.off` 然后重启一次。

**方式 C — 电脑用 adb**

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb shell "/debug_ramdisk/su -c 'sh /data/adb/modules/mu300_linux_switch/switch.sh'"
```

**方式 D — 先看状态再切（推荐，能提前发现问题）**

```powershell
& $adb shell "/debug_ramdisk/su -c 'sh /data/adb/modules/mu300_linux_switch/switch.sh status'"
```

正常应输出：

```
running slot   _a
slot a         priority 15, tries 1, successful 1
slot b         priority 14, tries 1, successful 0
boot_b         the Linux boot image      ← 关键，必须是这一行
```

`--dry-run` 可以只算不写（不重启）：

```
misc  now: 5f61000042434142010200009f001e...
misc  new: 5f62000042434142010200009e002f...
dry run: nothing was written
```

### 1.3 ⚠️ 切换失败报「a boot image that is not Linux」

`switch.sh` 靠读 `boot_b` 偏移 44 的 **11 字节** `loglevel=5\0` 识别 Linux 镜像。
2026-10-10 我加的 `MU300_USBNET=rndis` 补丁把这里改成了 `loglevel=5 MU300_USBNET=rndis`，第 11 字节从 `00` 变 `20` → 识别失败 → **完全切不进 Linux**，而报错还指向「这是旧版 Android」。

已处理：
1. 撤掉该补丁（`boot/build-boot-image.py` 恢复成 `BOOT_CMDLINE = b'loglevel=5'`）
2. `switch.sh` 改成只比 **前 10 字节**，将来命令行尾部再加参数也不会误判

设备上 `boot_b` 的残留命令行无害（`boot/init` 未使用它），下次整机 `update` 会自动清掉。

### 1.4 从 OpenWrt 切回 Android

直接重启即可（`reboot` 或面板点重启）——按 1.1 就是回 Android。

---

## 2. WiFi 通道（日常首选）

### 2.1 连接参数

| 项 | 值 |
|---|---|
| SSID | `<你的热点名>` |
| 密码 | `<你的热点密码>` |
| 设备地址 | `192.168.77.1/24` |
| DHCP 池 | `.100` – `.249`，租期 12h |
| 5GHz | 信道 36，`802.11ac`，WPA2-PSK/CCMP |

判断 PC 连的是不是**这台设备的 Linux** 热点：看 **BSSID**。
- Linux 侧：`<Linux侧BSSID>`
- Android 侧：`<Android侧BSSID>`

**两个系统热点同名**，只看 SSID 分不出来。

### 2.2 SSH（推荐）

密码登录：

```powershell
ssh root@192.168.77.1        # 密码 <你的root密码>
```

**免密已配好**（2026-10-10）：PC 的 `~/.ssh/id_ed25519.pub` 已装到设备 `/etc/dropbear/authorized_keys`。

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519 root@192.168.77.1
```

用封装好的脚本更省事（`tools\mu300.ps1`）：

```powershell
# 执行命令
.\tools\mu300.ps1 -C "uci show wireless"

# 推文件（自动校验 sha256）
.\tools\mu300.ps1 -Push .\local.conf -To /etc/foo.conf

# 取文件
.\tools\mu300.ps1 -Pull /etc/config/network -Out .\network.txt

# 交互 shell
.\tools\mu300.ps1 -Shell
```

**坑**：
- **`scp` 不可用** —— dropbear 没编译 `sftp-server`（`ash: /usr/libexec/sftp-server: not found`）。文件只能走 `base64` 或 LuCI API。
- 系统自带 busybox **没有 `base64`**，得用 `/opt/mu300/bin/busybox base64`。
- dropbear 对 `authorized_keys` 很挑：文件必须 `0600`、root 属主。另外 rpcd 的 `file write` **不做 base64 解码**，会把 base64 文本原样写进去（我第一次就踩了，文件里存的是 `c3NoLWVkMjU1MTkg...`）。

### 2.3 LuCI 网页

```
http://192.168.77.1/cgi-bin/luci/
```

- root / `<你的root密码>`
- **末尾斜杠必须有**，少了会 403
- 未登录时 GET 返回 **403 + `X-Luci-Login-Required: yes`** —— 这是正常的「未登录」表现，不是登录坏了；此时也不下发 `sysauth` cookie
- 判断登录成功：POST 后出现 `302 Found` + `Set-Cookie: sysauth_http=...`

### 2.4 JSON-RPC / ubus（脚本化）

两个端点可用（实测 HTTP 200）：

```
http://192.168.77.1/ubus
http://192.168.77.1/cgi-bin/luci/admin/ubus
```

`/cgi-bin/luci/ubus` 是 404，别用。

用封装脚本（`tools\mu300-api.ps1`）：

```powershell
.\tools\mu300-api.ps1 -Call 'system board'
.\tools\mu300-api.ps1 -Call 'mu300dash signal'
.\tools\mu300-api.ps1 -Call 'uci get'  -Params '{"config":"wireless","section":"radio0","option":"disabled"}'
.\tools\mu300-api.ps1 -Login           # 只打印 session id
```

**坑**：JSON 里的引号经不起两层 `powershell.exe` 传递，会得到 `-32700 Parse error`（**看起来像协议错误，其实是引号问题**）。两个解法：
- 在 PowerShell 会话里**直接调**（不要嵌一层 `powershell.exe -File`）
- 参数写成文件：`-Params '@params.json'`（同 curl 的 `@` 约定）

---

## 3. USB 串口控制台（救命通道）

**这是网络全坏时唯一的入口**，不受防火墙影响。

```
COM12 / 115200 8N1 / 无流控
```

OpenWrt 的 `/etc/inittab` 里有 `ttyGS0::askfirst:/usr/libexec/login.sh`，所以直接给 root 提示符（无需密码）。

用 `tools\mu300-console.ps1`：

```powershell
# 只读
.\tools\mu300-console.ps1 -ReadSeconds 20

# 发命令
.\tools\mu300-console.ps1 -ReadSeconds 40 -Commands @('ip route','cat /tmp/mu300-lancheck.log')
```

**坑**：
- **别让 dnsmasq 在前台跑**（`-d`）：它会占住控制台，之后 shell 就失联，要发 Ctrl+C 才能拿回来。
- netifd 会不停重启 dnsmasq，手工 `killall` + 手工启动的实例常被顶掉，日志文件莫名是空的。
- 控制台有「Please press Enter to activate this console」，**开机后头几秒发的命令会丢**，先发一个空行。

---

## 4. USB 网络（RNDIS）

设备的 USB gadget 可以枚举成 RNDIS，PC 侧表现为「以太网 N / Remote NDIS based Internet Sharing Device」，会拿到 LAN 地址（实测 `192.168.77.247`）。

**⚠️ 不要同时开着 WiFi 和 USB 网络。** 两条链路在同一子网会导致设备侧出现**两条重复的 192.168.77.0/24 路由**，设备从 USB 回包，WiFi 客户端就连 ping 都不通（实测 100% 丢包）。

成因是上游 `10-mu300-usb` 的执行顺序缺陷（清理循环只处理「已经是网桥端口」的网卡，而 `rndis0` 是之后才加进网桥的）。已在补丁脚本第 11 步修好并实测验证。

需要用 USB 时，建议先断开 WiFi。

---

## 5. adb（Android 侧）

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb devices           # 序列号 <设备序列号>
```

**root 要点**（与常见设备不同）：
- `su` **不在 PATH** 上，也没有 `/system/bin/su`
- 真正的位置是 `/debug_ramdisk/su`（软链到 MagiskSU）
- **必须带 `-c`**：`/debug_ramdisk/su -c 'id'` ✓；`/debug_ramdisk/su id` 会开交互 shell、读到空 stdin 后什么都不输出（看起来像 su 坏了）
- `adb root` 不可用（production build）

```powershell
& $adb shell "/debug_ramdisk/su -c 'id'"
# uid=0(root) gid=0(root) context=u:r:magisk:s0
```

---

## 6. 离线挂载 Linux 分区（网络全坏时改文件）

设备在 Android 时，可以用 loop 设备挂载 Linux 的 ext4 区域直接改文件。

```powershell
& $adb shell "sh /data/local/tmp/am.sh /data/local/tmp/lx"
# MOUNTED /dev/block/loop32 on /data/local/tmp/lx
```

挂载后 Linux 根文件系统在 `/data/local/tmp/lx/openwrt-luci/`。

**坑 1**：脚本会报 `NO-LOOP-INDEX`。原因是 `/dev/block/loop32` 节点还没被 ueventd 建出来。手工补：

```powershell
& $adb shell "/debug_ramdisk/su -c 'losetup -o 27762098176 /dev/block/loop32 /dev/block/mmcblk0'"
& $adb shell "/debug_ramdisk/su -c 'mount -t ext4 -o noatime /dev/block/loop32 /data/local/tmp/lx'"
```

**坑 2**：**用完必须卸载**，否则残留的 loop 会让下次安装报 `ALREADY-MOUNTED loop32`。

```powershell
& $adb shell "/debug_ramdisk/su -c 'umount /data/local/tmp/lx'"
& $adb shell "/debug_ramdisk/su -c 'losetup -d /dev/block/loop32'"
```

关键路径：
- 偏移 `27762098176`
- 目标目录 `/data/local/tmp/lx/openwrt-luci/`
- 改完记得 `chmod 0755`（尤其 init 脚本）和 `sync`

**判断文件是否可执行**（真实案例）：`od -An -tx1 -N6 <file>` 应该以 `23 21 2f`（`#!/`）开头。若看到 `ef bb bf`（UTF-8 BOM）或 `ff fe`（UTF-16LE），这个脚本在设备上**跑不起来**，而且内核会**静默跳过**它。

---

## 7. 已验证的设备能力清单

JSON-RPC 登录后会返回完整 ACL，以下是**实测可用**的部分（`tools\mu300-api.ps1 -Call '<对象> <方法>'`）：

**uci**（读写）：`network` `wireless` `firewall` `dhcp` `dropbear` `system` `luci` `sqm` `uhttpd` `fstab` `unisoc_modem`

**file**（白名单路径）：`read` `write` `list` `remove` `exec` `stat`
白名单含 `/etc/dropbear/authorized_keys`、`/etc/rc.local`、`/etc/firewall.user`、`/etc/crontabs/root`、`/etc/sysupgrade.conf`、`/etc/apk/*`

**rc / service**：`list` `init` —— 启停服务

**system**：`board` `info` `reboot` `validate_firmware_image`

**mu300dash**（本项目专有，很有用）：
`sysinfo` `status` `signal` `sms_list` `sms_send` `sms_read` `at` `at_history` `usb_get` `usb_set` `usb_net_list` `usb_net_add` `power_get` `power_set` `ttl_get` `ttl_set` `lang_get` `lang_set` `lock_get` `lock_set`

**其它**：`iwinfo assoclist|scan|info`、`hostapd.* del_client|wps_start`、`luci.setPassword`、`luci.getRealtimeStats`、`luci.getProcessList`、`luci.getDHCPLeases`、`log read`、`network.interface dump`、`file exec`

实测样例：

```powershell
# 4G 信号（NR band 1，实测 RSRP -75.1 / SINR 21.2）
.\tools\mu300-api.ps1 -Call 'mu300dash signal'

# 系统状态（CPU 8 核、内存 1.5GB、存储 33GB、温度）
.\tools\mu300-api.ps1 -Call 'mu300dash status'

# 当前关联的客户端
.\tools\mu300-api.ps1 -Call 'iwinfo assoclist' -Params '{"device":"wlan0"}'

# 踢掉一个客户端
.\tools\mu300-api.ps1 -Call 'hostapd.wlan0 del_client' -Params '{"addr":"aa:bb:cc:dd:ee:ff","deauth":true,"ban_time":60000}'
```

配置类操作（**改完要 commit 才持久**）：

```
uci set → uci commit → 重启对应服务
```

`uci apply` / `confirm` / `changes` 也走同一套。

---

## 8. 常见故障处置

| 症状 | 原因 | 处置 |
|---|---|---|
| PC 能关联热点，但拿不到 IP / ping 不通 | fw4 的 lan 区没有 br-lan（`bridge_empty=1` + wlan0 后加入） | 见 `docs\04-WiFi与DHCP根因分析.md`；`uci add_list firewall.<lan>.device=br-lan` 后 **`firewall stop; firewall start`**（`restart` 会因 flowtable Resource busy 失败） |
| WiFi 连 ping 都不通，但 USB 网口正常 | 两条 192.168.77.0/24 重复路由（rndis0 争用） | `ip addr del 192.168.77.1/24 dev rndis0`；已修进补丁脚本第 11 步 |
| 热点完全不广播，dropbear 却正常 | `mu300-hw` 带 BOM/UTF-16 → 内核静默跳过 → WiFi 驱动没 insmod | 见 `docs\04-WiFi与DHCP根因分析.md`；`od -An -tx1 -N6 /etc/init.d/mu300-hw` 检查 |
| 切不进 Linux，报「not Linux」 | `boot_b` 偏移 44 的命令行被改过 | 见 §1.3 |
| 安装报 `ALREADY-MOUNTED loop32` | 上次挂载没卸载 | 见 §6 卸载步骤 |
| 改完配置重启就丢 | 没 `uci commit` | `uci commit <config>` |
| 装到设备上的脚本不生效 | 文件编码/换行不对 | `tools\audit-repo-encoding.ps1` 扫一遍（UTF-16/BOM/CRLF 都会被指出） |

---

## 9. 本仓库相关工具

| 文件 | 用途 |
|---|---|
| `tools\mu300.ps1` | SSH 操作封装：执行命令 / 推文件 / 取文件 / 交互 shell |
| `tools\mu300-api.ps1` | ubus JSON-RPC 客户端 |
| `tools\mu300-console.ps1` | USB 串口 COM12 读写 |
| `tools\apply-v50-patches.ps1` | 对上游仓库打全部 12 步补丁（幂等，含编码门禁） |
| `tools\audit-repo-encoding.ps1` | 扫描 UTF-16 / BOM / CRLF |
| `tools\collect-v50-logs.ps1` | 取回 `boot_b` 持久化日志（pstore + 48MiB 处），回 Android 后用 |
| `tools\watch-linux-boot.ps1` | 观察是否已切到 Linux |
| `docs\04-WiFi与DHCP根因分析.md` | WiFi / DHCP 三个根因的完整证据 |
| `docs\03-启动日志分析.md` | 早期配置分析 |

---

## 10. 未验证 / 待办

- **BROM 短接 + WPFlasher 刷回**：本文未复测，流程见 `V50\一键刷分区、备份还原工具\` 与 `V50\短接触点.png`；备份在 `backup\2026-10-09-pre-install\`（28 分区 597 MiB，含 `misc.img`）
- **设备上仍有旧版文件**：`/opt/mu300/bin/mu300-lancheck` 尚未更新到仓库版本。下次整机 `update` 会带上

---

## 附：实测网络吞吐（USB RNDIS vs WiFi）

2026-10-10 实测。**测的是 PC ↔ 设备之间的本地链路，不经过 4G**，所以既不消耗流量，也不会被运营商带宽掩盖。

### 结果

| 方向 | USB RNDIS（`192.168.77.247`） | WiFi（`192.168.77.232`） | 倍数 |
|---|---|---|---|
| **下行**（设备 → PC） | **308 / 309 / 304 Mbps**（约 308） | 239 / 230 / 237 Mbps（约 236） | 1.3× |
| **上行**（PC → 设备） | **405 / 382 / 408 Mbps**（约 398） | 160 / 126 / 119 Mbps（约 135） | **2.9×** |

每轮 256 MB，各 3 轮，数值稳定。

### 参照：链路标称速率

| 项 | 值 | 来源 |
|---|---|---|
| USB 链路实际协商 | **`super-speed`**（USB 3.0 = 5 Gbps） | `/sys/class/udc/25100000.dwc3/current_speed` |
| USB 控制器上限 | `super-speed-plus`（10 Gbps） | 同目录 `maximum_speed` |
| PC 侧网卡自报 | `LinkSpeed: 3.8 Gbps` | Windows `Get-NetAdapter`（按 USB 描述符推算） |

**实测 ~300–400 Mbps 相对 5 Gbps 标称只有约 6–8%**，这是 RNDIS 的常态，不是故障：
RNDIS 把每个以太帧当作一次 USB 传输来封装（协议开销比 NCM 大），加上这类嵌入式平台
在单条 TCP 流上的处理开销，都会把上限压到这里。要更高只能用 NCM（Windows 10 2004+ 免驱）
或者多流并发。

### 怎么复现

设备端（注意 **`/usr/bin/nc` 是系统 busybox，不支持监听模式**，必须用项目自带那个）：

```sh
# 上行测试的接收端；循环监听，否则 busybox nc 只接一次就退出
while true; do /opt/mu300/bin/busybox nc -l -p 5001 > /dev/null; done
```

下行测试：放一个大文件到 uhttpd 的 `/www` 下，然后从 PC 拉取。

PC 端（**必须绕开本机代理**，否则测的是代理；并用 `--interface` 强制走目标链路）：

```powershell
$c = "$env:SystemRoot\System32\curl.exe"
# 下行：curl 直接给出 speed_download
& $c -s -o NUL --noproxy '*' --interface 192.168.77.247 `
   -w '%{size_download} B  %{time_total}s  %{speed_download} B/s' `
   http://192.168.77.1/speedtest.bin
```

```powershell
# 上行：裸 TCP 灌数据（.NET，先 Bind 源地址再 Connect）
$buf = New-Object byte[] (256*1024)
$sock = New-Object Net.Sockets.Socket('InterNetwork','Stream','Tcp'); $sock.NoDelay = $true
$sock.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse('192.168.77.247'),0)))
$sock.Connect('192.168.77.1', 5001)
$ns = New-Object Net.Sockets.NetworkStream($sock, $true)
$total = 256MB; $sent = 0; $t0 = Get-Date
while ($sent -lt $total) { $ns.Write($buf,0,$buf.Length); $sent += $buf.Length }
"$([math]::Round($sent*8/1e6/((Get-Date)-$t0).TotalSeconds,1)) Mbps"
```

### 两个容易踩的点

1. **本机代理**：这台 PC 上 `http_proxy`/`https_proxy` 指向 `127.0.0.1:7897`（mihomo）。
   不加 `--noproxy '*'` 的话，测到的是代理回环，不是 V50 这条路 —— 我第一次就被骗过，
   误以为"IPv4 全通"。
2. **`/usr/bin/nc` 不能监听**：它是系统 busybox 的，用法只有 `nc [IPADDR PORT]`。
   带 `-l -p` 的是 `/opt/mu300/bin/busybox`（项目自带的 Ubuntu 版本）。

### 结论

**USB RNDIS 是这台设备上更快的通道**，尤其上行（~3× WiFi）；但按第 4 节，它与 WiFi
同时启用会产生重复路由导致 WiFi 不通，**日常仍建议只留 WiFi**，需要大流量传输时再切 USB。
