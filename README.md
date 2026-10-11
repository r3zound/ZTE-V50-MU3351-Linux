# ZTE V50 (MU3351) — 刷入 mu300-linux 双系统

把 **ZTE V50**（型号 `MU3351`）刷成 **Android + OpenWrt 双系统**：保留原厂 Android，另在 eMMC 空闲区装一个完整的 Linux，两边可随时切换。

本仓库是**实测记录 + 补丁 + 工具**，不是固件分发站。所有结论都来自真机验证，每一步都附了验证命令。

| | |
|---|---|
| 目标设备 | ZTE V50（`MU3351`，板型 `ums9620_2h10_feimao`） |
| 上游项目 | [dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux)（MIT） |
| 验证版本 | 上游 **v2026.10.12** + 本仓库 19 步补丁 |
| 系统 | Android 13 + OpenWrt 25.12.5（`openwrt-luci` 面板版） |
| 内核 | **5.4.254**（vendor 基线）或 **6.18.55**（主线，实测可用）。安装向导本来就会问，已装设备可 `mu300-update kernel` 就地切换、`rollback-boot` 回退。见 `docs/07-6.18内核与按键与监管域.md` |
| 风险 | 低。不动 `boot_a` / GPT / `userdata`；只写 Linux 区、`boot_b`、`misc` 的 32 字节 |

---

## 1. 刷完能得到什么

| 能力 | 具体表现 |
|---|---|
| **WiFi 热点可连且能拿 IP** | 广播热点，客户端自动获得 `192.168.77.100-249` 段地址，能上网 |
| **USB 网络可选** | 切成 RNDIS 后 PC 出现网卡并拿到 LAN 地址，USB 也能上网 |
| 实测吞吐 | 单流：USB RNDIS 上行约 **398 Mbps** / 下行约 **292 Mbps**；WiFi 约 **135 / 236 Mbps**。链路经实测确为 **USB 3.0 SuperSpeed**（`bcdUSB 0x0320` / `current_speed=super-speed`），但单条 TCP 流只能拿到 300–400 Mbps，想跑满要**多流并发**。测法与「一种会被 `nc` 循环伪装成"不扩展"的错测法」见 `docs/06-OpenWrt操作手册.md` 附录 |
| **实体按键** | 短按：热点 **2.4GHz ↔ 5GHz**（闪 2 下确认）；按住 **10 秒**：重启设备，三色轮流闪到下电（V50 的键报 KEY_FN=464，上游只认 116/138，故原先无反应。见 §4.6） |
| **指示灯** | **无外网=红 / 有网+5GHz=白 / 有网+2.4GHz=蓝**。面板彩灯是 I2C 上的 AW9523B，由 mu300-led 用户态直控（不是 sysfs 里的 sc27xx:*，那是背光）。切频段后自动跟随。F50/U30 Air 的原灯语不受影响，可配。见 §4.7 |
| **无线国家码** | 默认 `US`：2.4GHz 允许 **30 dBm**（BO/CN 只有 20），且允许低段 5GHz 起 AP |
| 管理 | `ssh root@192.168.77.1`；LuCI `http://192.168.77.1/cgi-bin/luci/` |
| 一键切换 | 在 Android 侧一条命令进 OpenWrt；在 OpenWrt 里重启即回 Android |
| 救砖通道 | USB 串口 COM12（115200）直接给 root shell，不怕网络配坏 |
| 4G 共享 | 移动数据经 NAT 分给 WiFi / USB 客户端 |
| 失败自保 | Linux 起不来会自动回 Android；连续失败 5 次也回 Android |

---

## 2. 前置条件

| 项 | 要求 | 怎么查 |
|---|---|---|
| 机型 | ZTE V50 / `MU3351` | `adb shell getprop ro.product.model` |
| 板型 | `ums9620_2h10_feimao` | `adb shell getprop ro.hardware` |
| **当前槽位必须是 `_a`** | 安装器硬性要求 | `adb shell getprop ro.boot.slot_suffix` |
| Root | Magisk 已装，能拿 uid=0 | 见下方注意 |
| 空闲空间 | 分区后空闲区 ≥ 约 1 GiB（实测 32.4 GiB） | `install.ps1 -Check` |
| 供电 | 全程稳定（刷机中掉电要 BROM 救砖） | —— |

> ⚠️ **V50 的 root 入口与常见设备不同**：`su` **不在 PATH**，也没有 `/system/bin/su`。
> 真正的位置是 `/debug_ramdisk/su`（软链到 MagiskSU），而且**必须带 `-c`** ——
> 不带会开一个交互 shell、读到空 stdin 后什么都不输出，看起来像 su 坏了。
>
> ```sh
> /debug_ramdisk/su -c id     # ✅
> /debug_ramdisk/su id        # ❌ 静默无输出
> ```

---

## 3. 快速开始

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$R   = '<本仓库克隆到某处>'          # 例：D:\V50

# 0) 备份（必做）
& "$R\tools\backup-v50-partitions.ps1"

# 1) 取上游源码（版本要匹配，见 3.1）
git clone https://github.com/dikeckaan/mu300-linux "$R\mu300-linux"

# 2) 打补丁（19 步，幂等，可重复跑）
& "$R\tools\apply-v50-patches.ps1" -Repo "$R\mu300-linux"

# 3) 只读检查
& "$R\mu300-linux\install.ps1" -Check

# 4) 安装
& "$R\mu300-linux\install.ps1" -Lang zh -NoSelfUpdate -Answers "$R\answers.txt"

# 5) 装机后设置（决定"能不能上网"，别跳过）—— 见第 5 节
```

### 3.1 版本要匹配

`tools\apply-v50-patches.ps1` 里的锚点是按上游 **v2026.10.12** 的行写的。
换版本前先看它跑完有没有 `MISS`：**任何一步 MISS 都必须人工确认**，别硬刷。

### 3.2 安装答案文件

`answers.txt` 一行一个答案，顺序固定（实测可用的一份）：

```
2        系统：OpenWrt
2        变体：面板版（openwrt-luci）
yes      机型识别不是 F50，继续（补丁已认出 V50，这步一般不再问）
5        连续失败 5 次就回 Android
yes      导入 Android 的热点名与密码
yes      包含 Mali GPU 文件
no       不装额外组件
1        内核：5.4（测试最久，最稳）
update   安装模式：保留已有配置
<root密码>      两遍，你自己定
<root密码>
INSTALL  最终确认（必须是大写 INSTALL）
```

**成功标志**：输出 `MU300-INSTALL-OK`，且安装日志里能看到
`8 entries from ...\openwrt\vendor-extra`（说明补丁注入生效）。

> ❌ **不要设置环境变量 `MU300_USBNET`**。它按环境变量语义工作，写在 boot 镜像命令行上无效，
> 而且会破坏 Android 侧对 Linux 镜像的识别，导致**再也切不进 Linux**。要 RNDIS 请看第 5.3 节。

---

## 4. 必须打的补丁，以及不打会怎样

上游对 V50 有 4 个会直接导致"刷完不能用"的缺陷。`tools\apply-v50-patches.ps1` 共 19 步：

| 步 | 修什么 | 不打会怎样 |
|---|---|---|
| 1 | 机型识别接受 `V50` / `MU3351` | 安装器把设备当"非 F50"拒绝继续 |
| 2 | 守住内核命令行恰为 `loglevel=5` | 多一个字段 → **Android 侧再也切不进 Linux**，且报错指向错误方向 |
| 2b | `switch.sh` 只比命令行前 10 字节 | 同上（让命令行以后再加参数也不会误判） |
| 3 | `mu300-hw` 每步 bring-up 加超时 | 某步 hang 住会一并丢掉网络和登录 |
| 4 | `mu300-post` 只在 SSH 在听时才 re-arm | 坏启动被标记成好的，**两个回退计数器每次都被清零，设备再也回不了 Android，断电也没用** |
| 5 | 新增 `mu300-lancheck`（每次开机记录 LAN 关键状态） | 坏启动和好启动长得一模一样，无从排障 |
| 6 | `vendor-overlay.py` 支持打包 overlay 树 | **改 `openwrt/overlay/` 完全不生效**（见下） |
| 7 | 把改过的 OpenWrt 文件镜像进 `openwrt/vendor-extra/` | 同上 |
| 8 | 安装器探测可用的 `su`（`/debug_ramdisk/su`） | 报 "su does not work"，但 root 其实是好的 |
| 9 | **`mu300-hw` 去 BOM + 强制 UTF-8/LF** | 内核读不了 shebang → **静默跳过 → WiFi 驱动永不加载 → 热点根本不广播** |
| 10 | **lan 防火墙上显式加 `br-lan`** | **客户端能连上却拿不到 IP**（最隐蔽的一个） |
| 11 | **`rndis0` 加入网桥后再清一次地址** | 用 RNDIS 时产生重复路由，WiFi 连 ping 都不通 |
| 12 | **关掉 flow offload**（`accept_to_wan` 为空 + `fw4 reload` 被 `Resource busy` 挡住） | **转发的 TCP 全被 RST**：客户端能解析域名却打不开任何网页，像「没有 DNS」 |
| 13 | **修正 `board.json` 里的 `eth0`**（改成实际的 `br-lan`） | LuCI 端口状态永远显示一个**不存在的 `eth0` 未连接**（armsr 基础镜像的残留） |
| 14 | **状态看板的 USB 指示器按实际网卡名取数**（`usb0` 或 `rndis0`） | 看板的「USB 网络」永远显示**未连接**，哪怕链路正通（RNDIS 模式下网卡叫 `rndis0`） |
| 15 | **状态看板的 DNS 改用 `jsonfilter` 解析** | 原来的 sed 模式**永远匹配不上**，`DNS` 一栏永远是 `--`，哪怕 WAN 上配着两个 DNS |
| 16 | **主机名 `ZTE-V50`、时区 `Asia/Shanghai`、无线国家码 `US`** | 提示符/页面标题还是旧名、时区是 +03、5GHz 因监管域起不了 AP（见 §4.4） |
| 17 | **apk 软件源指向清华 TUNA 镜像** | 4G 下官方源慢 2.25 倍；换成阿里云则**根本装不了包**（见 §4.3） |
| 17b | 把上面改过的文件镜像进 `openwrt/vendor-extra/`（**必须在所有内容修改之后**） | 预编译安装只读 vendor-extra，镜像早了就发出去未修补的版本（见 §4.5） |
| 18 | 编码硬门禁（UTF-16 / BOM / CRLF 直接报错） | 把坏文件发到设备上才发现 |
| 19 | **灯光方案一致性门禁**（三个脚本的互相调用 + 必须进 vendor-extra） | 半套方案**全是静默失效**：按键调一个 `mu300-led` 没有的子命令，只是打印用法然后什么也不做 |

### 4.1 第 15 步：为什么 DNS 那一栏永远是 `--`

看板的 DNS 读 `wan.dns`，后端 `dashboard-info` 原来这样取：

```sh
jarr_dns() { printf '%s' "$1" | sed -n 's/.*"dns-server": *\[\([^]]*\)\].*/\1/p' | tr -d '"' ; }
```

两个各自独立、且都成立的原因，任一个都足以让它取不到值：

1. `ubus call network.interface.wan status` 是**多行漂亮打印**的，`[` 和 `]` 不在同一行，
   逐行的 sed 一行都匹配不到。旁边的 `jval()` 逃过一劫，纯粹因为它读的
   `up` / `uptime` / `proto` / `address` 都是标量，ubus 不会拆行。
2. 这种模式开头的 `.*` 是**贪婪**的，就算压成一行，它也会咬住文档里**最后**一个
   `dns-server` —— 也就是 `inactive` 块里那个**空数组**，而不是真的那个。

这台设备上 WAN 一直配着两个 DNS，页面一直显示 `--`。改用 `jsonfilter` 后两个都正常显示
（每个一行）。

### 4.2 为什么第 6/7 步是必需的

`install.ps1` 装的是**预编译 release 的 rootfs**，`openwrt/overlay/` 只在
`openwrt/build-rootfs.sh` 从源码构建时才被读取 —— 所以只改 overlay 树，
对预编译安装**毫无影响**，改了等于没改。

真正生效的通道是：`openwrt/vendor-extra/` → `tools/vendor-overlay.py` 打进
`mu300-vendor-<os>.tar.gz` → `android-install.sh` 在解包 rootfs **之后覆盖解包**。

还有两个致命细节：

- **Windows 存不了 Unix 权限**，打包时若一律写 0644，**init 脚本会丢可执行位，开机直接坏**。
  注入函数对 `etc/init.d/`、`etc/uci-defaults/`、`etc/hotplug.d/`、`opt/mu300/bin/`、`lib/`、`usr/`
  显式写 **0755**。验证：`tar -tvzf mu300-vendor-openwrt-luci.tar.gz` 应显示 `-rwxr-xr-x`。
- **编码**：`openwrt/overlay/etc/init.d/mu300-hw` 在上游仓库里是 **UTF-16LE**。
  写成 UTF-16 或带 BOM 的文件在设备上**跑不起来，而且内核是静默跳过**——控制台没有任何报错。
  所以补丁脚本第 18 步会扫描所有要发到设备的目录，发现 UTF-16/BOM/CRLF 直接中止。

### 4.3 为什么软件源不能用阿里云

OpenWrt 25.12 用 **apk**（不是 opkg），源文件是 `/etc/apk/repositories.d/distfeeds.list`。
本仓库把它指向 **清华 TUNA**，并在设备上实测过：

| 镜像站 | 8 条索引 | `apk update` |
|---|---|---|
| `mirrors.aliyun.com/openwrt` | **0/8，全 404** | **rc=8 失败，可见包从 11178 掉到 226** |
| **`mirrors.tuna.tsinghua.edu.cn/openwrt`** | 8/8，重复请求 20/20 | rc=0，4 s，11178 个包 |
| `downloads.openwrt.org`（官方） | 8/8，重复请求 20/20 | rc=0，7 s，11178 个包 |

原因很具体：**阿里云的 `releases/` 只同步到 `25.12.0-rc2`，没有本镜像用的 25.12.5**
（`build-rootfs.sh` 里 `MU300_WRT_VER` 的默认值）。8 条索引 URL 全部 404，而设备上
**不会有任何报错**——镜像"配好了"、apk 也能跑，要到真正装东西时才炸。

华为云 `repo.huaweicloud.com/openwrt` 更阴：对不存在的路径返回 **200 + HTML 页面**，
`HEAD` 探测会判定"可用"。

清华的索引与官方**逐字节相同**（sha256 一致，110251 字节），不是改过的内容。
改回官方只需换主机名，路径一个字不用动。详见 `docs/06-OpenWrt操作手册.md` §10。

### 4.4 5GHz 热点为什么起不来：监管域（以及为什么没人报错）

症状是 hostapd 直接失败、**设备上任何地方都不报错**：

```
hostapd: Frequency 5180 (primary) not allowed for AP mode, flags: 0x40853 NO-IR
hostapd: Could not select hw_mode and channel. (-3)   →  AP-DISABLED
```

链条是：`cfg80211` 在 rootfs 挂载**之前**就要 `regulatory.db`，那次必然失败
（`failed to load regulatory.db`）→ cfg80211 停在**世界域** → 世界域里 5GHz 全是 `NO-IR`
（禁止主动发射）→ hostapd 不能在该信道起 AP。

实测确认：手动跑一次 `regdb-load` 之后，`iw reg set TR/CN/US/BO` **立刻全部生效**；不跑则
`iw reg set` 无效、信道照样被拒。

**修法**：`mu300-lancheck` 每次开机**先补喂 `regdb-load`，再**按 `operstate` + 网桥端口判断并
`wifi down; wifi up` 重试（最多 3 轮）。顺序重要——必须在重启无线之前，hostapd 才能读到国家码。

> 判据必须是 `operstate`，不能只看「是不是网桥端口」：6.18 上 wlan0 **一直在网桥里**，是**射频**
> 起不来，旧判据从不触发、日志看着像通过。

### 4.5 第 17b 步：镜像必须排在所有修改之后

第 7 步原本既定义镜像清单**又**执行拷贝，而第 10/12/13/16 步在那之后还会继续改
`openwrt/overlay/`。后果：**单次干净运行产出的 vendor-extra 是改动前的内容**，而预编译安装
只读 vendor-extra —— 那样的设备会拿到未修补的 `90-mu300` / `10-mu300-usb` / `dashboard-info`，
本仓库却看上去一切正常。重复运行会掩盖它（每次拷的是上一轮的成品）。

已改成函数 `Mirror-VendorExtras`，在第 17b 步（所有内容修改之后、编码门禁之前）调用。
**同类盲区**：`mu300-buttons` 只在 `rootfs/overlay/` 里，原先不在镜像清单内，会同样漏掉，已补上。

---

## 4.6 实体按键：短按切 2.4/5GHz，长按 10 秒重启

> **前提**：`mu300-buttons` 只认上游的 `KEY_POWER=116` / `KEY_WIFI=138`（U30 Air 的键）。
> **V50 一个都不报**，所以按键此前完全没反应。

V50 实测键码（解 `/dev/input/event0` 得到）：

| 设备树节点 | `linux,code` | 十进制 | 备注 |
|---|---|---|---|
| `key-power` | `0xBE` | 190 | KEY_F20 |
| `key-volumedown` / `key-volumeup` | `0x72` / `0x73` | 114 / 115 | |
| **`key-function`** | `0x1D0` | **464** | **KEY_FN —— V50 唯一的实体键** |

绑定后：**短按** → `mu300-wifi-band toggle`（2g/ch6 ↔ 5g/ch36），并**先闪 2 下**确认；
**长按 10 秒** → 红/白/蓝**轮流闪**到设备重启。
长按阈值按设备树判断（`key-function` 节点只有 V50 有，模型字符串与 F50 相同，分不出来）：

```sh
HOLD=${MU300_BUTTONS_HOLD:-$([ -d /proc/device-tree/gpio-keys/key-function ] && echo 10000 || echo 3000)}
```

实测：短按 → `band` 由 `2g ch=6` 变 `5g ch=36` ✅；长按 10 秒 → 重启并自动恢复热点 ✅。

> **按键"完全没反应"时，先数一下有几个按键读取进程**：
> ```sh
> ps w | grep -c '[m]u300-keys'      # 必须恰好是 1
> ```
> 上游的 `/etc/init.d/mu300-buttons` 没有 `stop_service()`，`restart` 停不掉旧实例，
> 第二个 `mu300-keys` 会同时读同一个 gpio-keys，**每次按键被处理两遍** ——
> 切频段切两次等于没切，灯也毫无反应，看起来像键坏了。补丁已补上 `stop_service()`（实测连重启 4 次，每次都只剩 1 套）。

> 按键"没反应"时，先看 `/run/mu300/power/state` 是否 `active`、`mu300-power daemon` 是否在跑 ——
> 上游逻辑里 **idle 状态下的第一次按下只唤醒、不执行动作**，别一上来就怀疑键码。

完整记录（含 6.18/7.2 内核切换与回退）见 `docs/07-6.18内核与按键与监管域.md`。

### 4.7 指示灯：无外网=红，有网+5GHz=白，有网+2.4GHz=蓝

V50 面板上的彩灯**不在 `/sys/class/leds` 里**。它是 I²C 总线 `i2c-3` 上的一颗 **Awinic AW9523B**
（`0x5b`，设备树 `/soc/ap-ahb/i2c@2270000/aw9523b_led@5b`），Android 侧由厂商模块 `aw9523b.ko` 驱动。
那个模块**搬不到本项目的内核上**（vermagic 不匹配且开了 modversions），所以本方案改成
**`mu300-led` 从用户态用 `i2cset` 直接驱动芯片** —— 不改内核、不写模块。

| 有无外网 | 频段 | 灯 | 寄存器掩码 |
|---|---|---|---|
| **无** | 任意 | **红** | `0x2894` |
| 有 | 5 GHz | **白** | `0xffff`（红+绿+蓝同亮） |
| 有 | 2.4 GHz | **蓝** | `0x9442` |

掩码取自**原厂设备树**的 `aw9523b,idx`（厂商自己的接线定义），三者并集 `0xffff`、互不重叠。

> **踩过的坑（已更正过一次错误结论）**：早先的版本把这三路写成 PMIC 的 `sc27xx:*` 并宣布"实测通过"。
> 那是错的 —— `sc27xx:*` 是 **PMIC 背光控制器**（`led-controller@180`），在 V50 上**不驱动任何可见灯珠**，
> 往它写 0/255 画面毫无变化。当时验的是寄存器回读值，而那三路从未点亮过一颗灯。
> **寄存器回读对 ≠ 灯亮了**：灯光验证必须以肉眼为准。
> 详见 `docs/08-灯光效果方案.md` 第〇节。

- **「有无网」的判据 = 调制解调器数据已连接**（`mobile-data` 的 `data on`/`data 5g` 事件），
  **不去 ping 外网**，不产生额外流量与延迟。注意它**不等于真的能上外网**（DNS 坏、路由坏时它照样是白/蓝）。
- **红优先**：三个状态里只有"没网"需要人处理，所以它盖过频段（无网 + 2.4GHz 显示红，不显示蓝）。
- **切频段后颜色自动跟随** —— 这是补丁里 `mu300-wifi-band` 补的那一句 `mu300-led wifi sync`。
  没有它，颜色会一直停在刚切走的那一档。
- **一次 `i2cset` 点亮整块面板**：16 个调光寄存器地址连续，芯片接受 I²C block 连续写
  （`i2cset -f -y 3 0x5b 0x20 <16 字节> i`，注意 mode 字母在最后）。所以改色不必先关别的颜色。
- **F50 / U30 Air 完全不受影响**：方案由 `LED_SCHEME=v50` + `LED_BACKEND=i2c` 打开，默认是 `classic`（原灯语）。

改颜色 / 亮度不用重新编译，改 `/etc/mu300/led.conf` 即可（三个掩码、`LED_I2C_GCR` 电流档
`0`=37mA/`1`=27.75mA/`2`=18.5mA/`3`=9.25mA、`KEY_FLASH_COUNT`、`LED_LEVEL` 百分比）。
**想把灯变回 F50 原来的样子**：注释掉 `LED_BACKEND=i2c` 那行。

> **`LED_AW_WHITE_LEVEL` 为什么是白色专用的一个值**：白色不是第四种颜色，是红+绿+蓝同时亮。每颗 LED
> 各自只吃自己那一路的电流，但眼睛看到的是三个发光体叠加，所以同样的 DIM 值下白色明显比单色亮。
> 这个值就是用来把白色压回和红/蓝同一水平的。本机从 100% 一路走到 **10%** 才定下来（夜间安静的白、
> 仍看得出是白）。改它只需一行 + `mu300-led data on`，不用重编译。

四个只有实施时才会撞上、且已修的问题（完整说明见 `docs/08-灯光效果方案.md` 第七节）：

1. **`i2c-dev` 是模块且没人加载它** —— 引用计数为 0，重启后 `/dev/i2c-3` 不存在，灯光会**毫无报错地保持全黑**。
   `mu300-led` 现在自己 `modprobe`（已用 `rmmod` → 运行 → 自动恢复实测）。
2. **开机没人画第一次灯** —— 只有网络事件才重绘，modem 报告前面板全黑像坏了。
   `init.d/mu300-buttons` 的 `start_service()` 现在画一次（开机先红，连上后转白/蓝）。
3. **设备的 `sleep` 不吃小数秒** —— OpenWrt 自带 busybox 直接报 `sleep: invalid number`，
   上游 `mu300-led nap()` 的兜底把 0.15 秒变成整整 1 秒：**闪 2 下会变成 4 秒**。
   已改成优先用发布版自带的 busybox（带 `FANCY_SLEEP`）。
4. **编码门禁（第 18 步）从来没检查过任何文件** —— `Get-ChildItem -Recurse -File -Path "$tree\*"`
   在 PowerShell 5.1 下返回 **0 个文件**，门禁却每次打印"ok"。一个带 BOM/CRLF 的脚本照样会发到设备上。
   已修，并注入 BOM 做反向测试确认它现在会失败。

完整实测记录（**逐条肉眼确认**，含寄存器布局、掩码换算与退路）见 `docs/08-灯光效果方案.md`。

---

## 5. 装机后设置（决定"能不能上网"）

### 5.1 确认 lan 防火墙区包含 `br-lan`

补丁第 10 步会通过 `90-mu300` 自动加上，但**必须复核**：

```sh
uci -q get firewall.@zone[0].device            # 期望：br-lan
nft list chain inet fw4 input | grep br-lan    # 期望：iifname "br-lan" jump input_lan
```

**为什么容易漏**：fw4 是从**网桥端口**推导某个区包含哪些接口的。`br-lan` 声明为
`bridge_empty=1`（有线 LAN 不该等一个还不存在的成员），而 `wlan0` 是 netifd 之后才加进网桥的 ——
等 fw4 渲染规则集那一刻，**lan 区一个设备都没有**：input 链里没有 `br-lan` 的跳转，策略是 `drop`，
客户端发的包全被丢掉。

这时的假象极其逼真：热点正常广播、`wlan0` 是 `br-lan` 的端口、`br-lan` 有 `192.168.77.1/24`、
dnsmasq 在 `0.0.0.0:67` 监听且 `dhcp-range` 正确、dropbear/uhttpd 都在听 ——
**只有渲染后的规则集能看出 lan 区其实是空的**。只读 `/etc/config/firewall` 会得出"防火墙没问题"的错误结论
（那里面 `input='ACCEPT'` 明明写着）。

若缺失，手工补（**`restart` 会因 flowtable 占用失败，必须 stop 再 start**）：

```sh
uci add_list firewall.@zone[0].device='br-lan'
uci commit firewall
/etc/init.d/firewall stop; sleep 3; /etc/init.d/firewall start
```

### 5.2 确认 `mu300-hw` 是纯 UTF-8、无 BOM

```sh
od -An -tx1 -N6 /etc/init.d/mu300-hw     # 必须是 23 21 2f（即 "#!/"）
```

若是 `ef bb bf`（UTF-8 BOM）或 `ff fe`（UTF-16LE），内核**无法解析 shebang、静默跳过该脚本**：
控制台没有报错、日志也查不到，**WiFi 驱动永不 `insmod`**（无 `wlan0`、热点不广播），
而 dropbear/uhttpd 照常运行，让人以为一切正常。

### 5.3 设置 USB 网络模式（想要 USB 上网才做）

在 LuCI：

```
http://192.168.77.1/cgi-bin/luci/admin/modem/device  →  USB 网络模式 → 选 RNDIS → 保存
```

等效命令：

```sh
ubus call mu300dash usb_set '{"kind":"net","value":"rndis","scope":"permanent","auto":"1"}'
ubus call mu300dash usb_get      # 复核：net_mode 应为 rndis
```

它把选择写进所选系统的 `/etc/mu300/usb-net`；每次开机 `boot/init` 读它，必要时**重绑一次 gadget**
（凭据写在 `/run/mu300/usb-net-applied`）。完整机制见 `docs/01-可行性评估.md` 的
「USB 网络模式（RNDIS）的正确做法」一节。

> ⚠️ **RNDIS 与 WiFi 不要同时用**。两条链路在同一子网会让设备产生两条重复的
> `192.168.77.0/24` 路由，回包走 USB → WiFi 客户端能关联、能拿租约，却连 `ping br-lan` 都不通。
> 补丁第 11 步修好了根因，但**最省事的做法仍是只留一条链路**。
>
> ⚠️ **`update` 模式安装会覆盖 `etc/mu300/`**，所以每次整机安装后要重设一次。

### 5.4 配上 SSH 免密（可选）

```powershell
& "$R\tools\mu300.ps1" -C "mkdir -p /etc/dropbear"
& "$R\tools\mu300.ps1" -Push "$env:USERPROFILE\.ssh\id_ed25519.pub" -To /etc/dropbear/authorized_keys
& "$R\tools\mu300.ps1" -C "chmod 600 /etc/dropbear/authorized_keys; chmod 700 /etc/dropbear"
ssh -i $env:USERPROFILE\.ssh\id_ed25519 root@192.168.77.1
```

> **`scp` 不可用**：dropbear 没编译 `sftp-server`。传文件请用 `tools\mu300.ps1 -Push/-Pull`
> （base64 + 设备自带的 `/opt/mu300/bin/busybox base64`；**系统 busybox 没有 base64 applet**）。

---

## 6. 验收清单

任何一条不过，回到第 5 节对应小节。

```
□ 设备开机进了 OpenWrt（不是 Android）：adb 消失、COM12 出现
□ 能扫到热点，能关联
□ 客户端拿到 192.168.77.100-249 的地址（不是 169.254.x）
□ 客户端 ping 192.168.77.1 通
□ 客户端能上网（ping 223.5.5.5、能解析域名）
□ ssh root@192.168.77.1 能进
□ http://192.168.77.1/cgi-bin/luci/ 能打开
□ od -An -tx1 -N6 /etc/init.d/mu300-hw  给出 23 21 2f
□ uci -q get firewall.@zone[0].device   给出 br-lan
□ ip route | grep -c 192.168.77         给出 1（不是 2）
□ 串口 COM12 115200 有 root@mu300:~#
□ 在 Android 里 su -c mu300-linux 能再进 OpenWrt
```

`ip route | grep -c 192.168.77` 必须是 **1** —— 这是第 5.3 节路由冲突问题的最简判据。

---

## 7. 两个系统的切换

**关键认知**：在 OpenWrt 里点重启**必然回 Android**，这是设计而非故障。
Linux 启动早期就自己把 Android 的 boot 控制块写回 misc，所以 **Linux 是一次性试用** ——
每次进 Linux 都必须从 Android 侧再切一次。

```powershell
# 从 Android 切进 OpenWrt（先看状态，再切）
& $adb shell "/debug_ramdisk/su -c 'sh /data/adb/modules/mu300_linux_switch/switch.sh status'"
& $adb shell "/debug_ramdisk/su -c 'sh /data/adb/modules/mu300_linux_switch/switch.sh'"
```

`status` 正常应输出 `boot_b   the Linux boot image`。

**更省事的做法**：本仓库提供一个 UFI-TOOLS 插件，在 Android 侧的管理界面
（`192.168.0.1:2333`）加一个「重启到 OpenWrt」按钮，点一下就行，不用开电脑。
见 `plugins/ufi-tools-restart-to-openwrt.js`，安装方式见 `docs/06-OpenWrt操作手册.md`。

> 若模块目录里出现 `disable` 文件，Magisk 会把它当停用：`mu300-linux` 不在 PATH、
> 面板的 Action 按钮也不出现。改名成 `disable.off` 即可（可逆）。

---

## 8. 目录结构

```
README.md                  本文件：完整刷机步骤
docs/
  01-可行性评估.md          硬件对照、RNDIS 机制、执行路径
  02-首次刷机与修复历程.md    第一次刷机的现场记录（⚠️ 部分结论后已被推翻，见文首提示）
  03-启动日志分析.md         直读设备配置得出的分析
  04-WiFi与DHCP根因分析.md   三个根因的完整证据链（WiFi 不广播 / DHCP 拿不到 IP / 路由冲突）
  05-一键复刻指南.md         分阶段清单式复刻步骤 + 验收清单
  06-OpenWrt操作手册.md      刷完后的日常操作（各通道、坑、能力清单）
07-6.18内核与按键与监管域.md 6.18/7.2 内核切换（含 rollback）、5GHz 监管域根因、实体按键键码与映射
08-灯光效果方案.md         灯语表、三态实现、实测结果、两个只有实施时才发现的坑与退路
tools/
  apply-v50-patches.ps1     19 步补丁（幂等，含编码与灯光门禁）★核心
  backup-v50-partitions.ps1 28 分区备份 + sha256 校验
  audit-repo-encoding.ps1   扫 UTF-16 / BOM / CRLF
  collect-v50-logs.ps1      回 Android 后取 Linux 的持久化日志
  watch-linux-boot.ps1      观察是否切到了 Linux
  mu300.ps1                 SSH：执行命令 / 推文件 / 取文件
  mu300-api.ps1             ubus JSON-RPC 客户端
  mu300-console.ps1         USB 串口 COM12 读写
  push-file.ps1             推**大文件**到设备（分块；单条 argv 装不下时会静默断连）
  led-scheme-test.sh        灯光方案的无设备回归测试（假 sysroot）★
  led-probe.sh              设备侧：报告三色与当前网络/频段状态（不用眼睛也能确认点亮了哪路）
  buttons-audit.sh          设备侧：数有几个按键读取进程（多于 1 就是 §4.6 那个坑）
plugins/
  ufi-tools-restart-to-openwrt.js   UFI-TOOLS 一键切换插件
patches/
  v50-changes-vs-upstream-v2026.10.12.patch   对上游的完整改动（LF，可 git apply）
probe/
  可行性探测脚本（GPT / 空间 / 硬件探测）
```

### 本仓库**不含**什么，为什么

| 没有 | 原因 |
|---|---|
| 厂商刷机工具、固件包、一键 Root 包 | 第三方版权物，且体积以 GB 计。请去对应来源自取 |
| 官方插件全集 / 网盘资源 | 同上 |
| 设备分区备份 | 含 **IMEI 与射频校准**，属个人敏感数据，**绝不能公开**。请自己备份 |
| 任何设备密码 / 序列号 | 本仓库的文档已用占位符（`<你的root密码>` 等）替换。装机时自定 |

---

## 9. 已知限制

- **无显示输出**（USB-C 的 PD 芯片不应答）—— 无头设备，靠 SSH / 网页 / 串口
- **无声音**（无喇叭无麦克风）
- **无 SD 卡槽** —— 只能装 eMMC 空闲区（32.4 GiB，完全够用）
- **V50 的面板彩灯不在 sysfs 里** —— 它是 I²C `i2c-3` 上的 AW9523B，Android 用 `aw9523b.ko` 驱动，
  该模块在本项目内核上装不了（vermagic 不匹配 + modversions），Linux 侧改由 `mu300-led` 用户态直控
  （`LED_BACKEND=i2c`）。所以 `mu300-led test` 遍历 sysfs 时点不到它，属外观问题，不影响网络与数据。
- **纯 WPA3 不支持**（该 WiFi 驱动无 SAE）
- 6.18 内核偶发启动挂死（约 1/20，会自动回 Android）→ 首次建议用 **5.4**

---

## 10. 排障速查

| 症状 | 原因 | 去哪 |
|---|---|---|
| 能关联热点，但拿不到 IP / ping 不通 | fw4 的 lan 区是空的 | 5.1 |
| **能解析域名、能 ping 通网关，但打不开任何网页** | `accept_to_wan` 为空 + flow offload 挡住了 `fw4 reload` | 第 4 节第 12 步（`nft list chain inet fw4 accept_to_wan` 为空即命中） |
| **LuCI 端口状态显示一个不存在的 `eth0`「未连接」** | armsr 基础镜像的 `board.json` 把 LAN 设备写成 `eth0` | 第 4 节第 13 步 |
| **状态看板的「USB 网络」显示未连接，但链路是通的** | 后端写死读 `usb0`，RNDIS 模式下网卡叫 `rndis0` | 第 4 节第 14 步 |
| **状态看板的「邻区」表全空** | **不是 bug**：调制解调器返回 0 个邻区（服务小区数据正常） | 见 `docs/04-WiFi与DHCP根因分析.md` 附录 |
| 热点根本不广播，但 SSH 正常 | `mu300-hw` 编码坏了（BOM/UTF-16） | 5.2 |
| WiFi 连 ping 都不通，USB 口却正常 | 两条重复路由 | 5.3 |
| 切不进 Linux，报「not Linux」 | boot 镜像命令行被改过 | 第 4 节补丁第 2/2b 步 |
| 设备再也回不了 Android（断电也没用） | 无条件 re-arm 把两个回退计数器都清了 | 第 4 节补丁第 4 步 |
| **`apk add` 装不上，或 `apk update` 退出码 8** | 镜像站没有本镜像用的 25.12.5（阿里云就是这样） | 第 4 节 §4.3 |
| **看板「链路与流量」里 DNS 永远是 `--`** | 后端用逐行 sed 取多行 JSON 的数组，匹配不上 | 第 4 节 §4.1（补丁第 15 步） |
| 装了 `luci-app-commands` 却找不到菜单 | 它在 **系统 → Custom Commands**，不是顶级菜单 | `/cgi-bin/luci/admin/system/commands` |
| 改了 `openwrt/overlay/` 却毫无效果 | 预编译安装只认 vendor-extra 通道 | 4.2 |
| 装上去的脚本不执行 | 编码问题 | `tools\audit-repo-encoding.ps1` |
| 安装报 `ALREADY-MOUNTED loop32` | 上次挂载没卸载 | 06 手册第 6 节 |

---

## 11. 命名约定与设备身份 —— 为什么内部仍叫 mu300

**V50（`MU3351`）与 F50（`MU300`）是同一块板**：`ro.hardware` 都是 `ums9620_2h10_feimao`，
SoC 同为 UMS9620 / T760，内核基线同为 5.4.254。所以上游对 F50 的支持**直接适用**，
`DEVICE=f50` 是**正确且经过实测**的路径 —— 补丁第 1 步只是让机型识别认下 `V50` / `MU3351`。

**内部标识一律沿用上游的 `mu300` 命名，这是有意的，不是遗漏。** 这些名字不是标签，而是已经
落地的关联契约，有些还是唯一的恢复通道：

| 标识 | 规模（本 fork 内） | 为什么不动 |
|---|---|---|
| `/opt/mu300`、`/etc/mu300` | 139 + 85 文件 | Android 侧安装器与 Linux 侧**跨系统**引用的绝对路径，boot initramfs 里也有 |
| `mu300-*` 命令（46 个脚本） | 292 文件 / 4162 处 | `/etc/init.d`、`inittab`、hotplug、cron 全按名字调用 |
| `MU300_*` 配置键 | 185 文件 / 2613 处 | 上游对外约定（`MU300_DEVICE`、`MU300_BOOT_OS` …） |
| `mu300cell` netifd proto | 21 文件 | UCI 里写着 `network.wan.proto='mu300cell'`：改了已有设备配置失效，且要同时改 `mu300cell.sh` / `mu300cell-v6.sh` / LuCI 的 `protocol/mu300cell.js` —— **漏一个 WAN 直接起不来** |
| `mu300dash` ubus 对象 | 34 文件 | LuCI 前端与 rpcd 后端必须同时改，漏一处整页空白 |
| **`mu300root` ext4 卷标** | 37 文件 | **`android-mount-mu300root.sh` 会校验这个卷标才挂载** —— 那是从 Android 挂载 Linux 分区修文件、Linux 网络全坏时唯一的手段。改了等于**自断退路** |
| Magisk 模块 `mu300_linux_switch` | 15 文件 | 模块 id 一变，Magisk 面板、`su -c mu300-linux`、开机钩子全要跟着 |

另外两条现实理由：

- **升级路径会裂开**：项目支持 `update` 安装（保留 `/etc/config`），改名后已有设备的配置全部指向旧名字 → 半坏状态。
- **与上游永久分叉**：上游每次发版都用旧名字加新代码，改名后每个 release 都要重新套一遍 rename 层，而**新文件必然漏改** —— 本项目里「漏改」的典型表现是**静默失效**（BOM 让 WiFi 不加载、`usb0`/`rndis0` 不匹配、`accept_to_wan` 为空），不是报错。

### 只改「给人看的名字」

目前**只有主机名**：刷完后是 **`V50`**（shell 提示符 `root@V50:~#`、页面标题都会跟着变）。
一条命令可回退：

```sh
uci set system.@system[0].hostname='mu300'; uci commit system; /etc/init.d/system reload
```

**刻意没改**：`view/mu300/device.js` 里两条用户可见的告警（"F50 has no battery …"）。
改英文 msgid 会让 `zh-cn` / `tr` 编译目录（`.lmo`）里的对应译文失配，在本来全中文的页面上
混出英文 —— 比现状更差；而且那句话对 V50 同样成立（同样没有电池）。

---

## 12. 致谢与许可

- **[dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux)** —— 上游项目，**MIT**。
  本仓库全部内容是对它的适配补丁与实测记录。
- 上游内核来自 ZTE 的 GPL 源码发布与 mainline Linux（**GPL-2.0**）；WiFi/蓝牙/GPU 驱动来自
  realme C51/C53 的 AndroidT 内核发布（**GPL-2.0**）。本仓库不重新许可这些组件。
- 本仓库自身的文档、脚本、插件：**MIT**，见 `LICENSE`。

> 刷机有风险。本仓库的每一步都在一台真机上跑通过，但硬件批次与固件版本会有差异。
> **务必先做完整备份**，并确认自己有 BROM 救砖的手段再动手。
