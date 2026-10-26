# ZTE V50 (MU3351) — 刷入 mu300-linux 双系统

把 **ZTE V50**（型号 `MU3351`）刷成 **Android + OpenWrt 双系统**：保留原厂 Android，另在 eMMC 空闲区装一个完整的 Linux，两边可随时切换。

本仓库是**实测记录 + 补丁 + 工具**，不是固件分发站。所有结论都来自真机验证，每一步都附了验证命令。

| | |
|---|---|
| 目标设备 | ZTE V50（`MU3351`，板型 `ums9620_2h10_feimao`） |
| 上游项目 | [dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux)（MIT） |
| 验证版本 | 上游 **v2026.10.26.1**（当前基线）+ 本仓库补丁 `patches/v50-changes-vs-upstream-v2026.10.26.1.patch`；旧基线 **v2026.10.23.2** 的补丁也保留着 |
| 系统 | Android 13 + OpenWrt 25.12.6（`openwrt-luci` 面板版） |
| 内核 | **7.3.0**（主线，2026-10-25 刷机实测可用）。上游**只给 V50 主线内核**（6.18 / 7.2 / 7.3），选 5.4 会被安装器直接拒绝。安装向导本来就会问，已装设备可 `mu300-update kernel` 就地切换、`rollback-boot` 回退。见 `docs/07-内核与按键与监管域.md` |
| 风险 | 低。不动 `boot_a` / GPT / `userdata`；只写 Linux 区、`boot_b`、`misc` 的 32 字节 |

---

## 1. 刷完能得到什么

| 能力 | 具体表现 |
|---|---|
| **WiFi 热点可连且能拿 IP** | 广播热点，客户端自动获得 `192.168.77.100-249` 段地址，能上网 |
| **USB 网络可选** | 切成 RNDIS 后 PC 出现网卡并拿到 LAN 地址，USB 也能上网 |
| 实测吞吐 | 单流：USB RNDIS 上行约 **398 Mbps** / 下行约 **292 Mbps**；WiFi 约 **135 / 236 Mbps**。链路经实测确为 **USB 3.0 SuperSpeed**（`bcdUSB 0x0320` / `current_speed=super-speed`），但单条 TCP 流只能拿到 300–400 Mbps，想跑满要**多流并发**。测法与「一种会被 `nc` 循环伪装成"不扩展"的错测法」见 `docs/06-OpenWrt操作手册.md` 附录 |
| **实体按键** | 短按：热点 **2.4GHz ↔ 5GHz**（闪 2 下确认）；按住 **10 秒**：重启设备，三色轮流闪到下电（V50 的键报 KEY_FN=464，上游只认 116/138，故原先无反应。见 §4.6） |
| **指示灯** | **网络灯 = 当前 SIM 槽那一组灯，按接入技术显示（5G=白 / 4G=蓝 / 无服务=红）；WiFi 灯 = 5GHz 白 / 2.4GHz 蓝**。面板彩灯是 I2C 上的 AW9523B，由**上游主线内核的 `leds-aw9523b` 驱动**（不是 sysfs 里的 `sc27xx:*`，那是背光）。切频段后自动跟随。F50/U30 Air 的原灯语不受影响。见 §4.7 |
| **无线国家码** | 默认 `US`：2.4GHz 允许 **30 dBm**（BO/CN 只有 20），且允许低段 5GHz 起 AP |
| 管理 | `ssh root@192.168.77.1`；LuCI `http://192.168.77.1/cgi-bin/luci/` |
| 一键切换 | 在 Android 侧一条命令进 OpenWrt；在 OpenWrt 里重启即回 Android |
| 救砖通道 | USB 串口 COM12（115200）直接给 root shell，不怕网络配坏 |
| 4G 共享 | 移动数据经 NAT 分给 WiFi / USB 客户端 |
| 失败自保 | 新写的启动镜像会先「试运行」一次，试运行期间连续失败 5 次才回 Android；确认能用后锁定，引导链不再自动回退 |

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
git -C "$R\mu300-linux" checkout v2026.10.26.1

# 2) 打 V50 移植补丁（28 个文件）★ 少了这步，按键就是死的 —— 见 3.2
git -C "$R\mu300-linux" apply "$R\patches\v50-changes-vs-upstream-v2026.10.26.1.patch"

# 3) 再跑 19 步脚本（幂等；此时应全部报 already，两道门禁通过）
& "$R\tools\apply-v50-patches.ps1" -Repo "$R\mu300-linux"

# 4) 只读检查
& "$R\mu300-linux\install.ps1" -Check

# 5) 安装
& "$R\mu300-linux\install.ps1" -Lang zh -NoSelfUpdate -Answers "$R\answers.txt"

# 6) 装机后设置（决定"能不能上网"，别跳过）—— 见第 5 节
```

### 3.1 版本要匹配

| 上游版本 | 用哪个补丁 | 脚本 |
|---|---|---|
| **v2026.10.26.1**（当前基线） | `patches/v50-changes-vs-upstream-v2026.10.26.1.patch` | 同上，19 步 |
| v2026.10.23.2（旧基线） | `patches/v50-changes-vs-upstream-v2026.10.23.2.patch` | 同上，19 步 |

脚本里的锚点原本是按 23.2 的行写的，26.1 改写了 `mu300-hw`（`hw_bringup()` 换了顺序、
加了 `ap_enabled_soon`），所以**逐行替换**而不是整块替换，两个基线都能命中。
换别的版本前先看它跑完有没有 `MISS`：**任何一步 MISS 都必须人工确认**，别硬刷。

### 3.2 第 2 步的 `git apply` 不能省

三处东西**只有补丁文件里有，脚本不会写**：

| 只有补丁带来的 | 脚本做了什么 | 少了会怎样 |
|---|---|---|
| `mu300-led` 的 `flash` 子命令 | 只检查，不写 | 按键调了一个 `mu300-led` 没有的子命令，打印用法然后什么也不做——**按键看起来像没反应** |
| `mu300-buttons` 认 `KEY_FN=464` + 长按 10 秒 | 只检查，不写 | V50 唯一的实体键**完全没反应**（上游只认 U30 Air 的键码） |
| `init.d/mu300-buttons` 的 `stop_service()` | 只检查，不写 | 第二个 `mu300-keys` 同时读同一个 gpio-keys，**每次按键被处理两遍**（切频段切两次等于没切） |

脚本第 19 步的灯光/按键门禁就是查这三样在不在——**不打补丁直接跑脚本，这一关过不去**。
反过来，先 `git apply` 再跑脚本，19 步会全部报 `already`，这是正常结果，不是出错。

### 3.3 安装答案文件

`answers.txt` 一行一个答案，顺序固定（实测可用的一份）：

```
2        系统：OpenWrt
2        变体：面板版（openwrt-luci）
yes      机型识别不是 F50，继续（补丁已认出 V50，这步一般不再问）
5        连续失败 5 次就回 Android
yes      导入 Android 的热点名与密码
yes      包含 Mali GPU 文件
no       不装额外组件
4        内核：7.3（主线，2026-10-25 实测可用）
update   安装模式：保留已有配置
<root密码>      两遍，你自己定
<root密码>
INSTALL  最终确认（必须是大写 INSTALL）
```

**成功标志**：输出 `MU300-INSTALL-OK`，且安装日志里能看到
`8 entries from ...\openwrt\vendor-extra`（说明补丁注入生效）。

> ⚠️ **V50 不能选 5.4 内核**。上游 `install.sh` 对 V50 会直接拒绝：
> 「The ZTE V50 runs a mainline kernel only: take the zip for kernel 6.18, 7.2 or 7.3 of this release」。
> 菜单是 `1=5.4 / 2=6.18 / 3=7.2 / 4=7.3`，**V50 的默认项是 2（6.18）**。
> 本仓库 2026-10-25 的实测用的是 **7.3**。

> ❌ **不要设置环境变量 `MU300_USBNET`**。它按环境变量语义工作，写在 boot 镜像命令行上无效，
> 而且会破坏 Android 侧对 Linux 镜像的识别，导致**再也切不进 Linux**。要 RNDIS 请看第 5.3 节。

---

## 4. 必须打的补丁，以及不打会怎样

上游对 V50 有 4 个会直接导致"刷完不能用"的缺陷。`tools\apply-v50-patches.ps1` 共 19 步。

> **上游自己已经原生支持 V50 了**（v2026.10.23.2 起）：SIM mux 与四板型卡映射
> （`port/drivers/misc/zte-v50-sim.c`、`rootfs/overlay/opt/mu300/lib/v50-card.sh`）、
> **主线内核的 AW9523B 面板灯驱动**（`port/drivers/leds/leds-aw9523b.c`）、
> 按设备树认出 V50 的 `mu300-device`（`v50_dt()` / `v50_fix()`）。
>
> 所以这 19 步解决的是**上游还没覆盖的那部分**，其中真正属于「上游没有、只有我们补」的只有 3 处：
>
> | 我们补的 | 上游缺什么 | 不补会怎样 |
> |---|---|---|
> | `mu300-led flash`（+ `LED_KEY_FLASH_COUNT`） | 上游只有 `alarm`（三色轮闪），没有「闪一下」这个动作 | 短按切频段要 `wifi reload`、颜色几秒后才变，**按键看起来像没反应** |
> | `mu300-buttons` 认 `KEY_FN=464` + 长按 10 秒 | 上游只认 `KEY_POWER=116` / `KEY_WIFI=138`（U30 Air 的键），**V50 一个都不报** | V50 唯一的实体键完全没反应 |
> | `init.d/mu300-buttons` 补 `stop_service()` | 上游这个脚本没有它，`restart` 停不掉旧实例 | 第二个 `mu300-keys` 同时读同一个 gpio-keys，**每次按键被处理两遍**（切频段切两次等于没切） |
>
> 其余 16 步在 v2026.10.12 时代就写好，v2026.10.23.2 上**仍然必要**（逐条核对过）。
>
> **2026-10-26：上游 26.1 又改了几处，这 19 步仍然全部必要，但有两点变了**
>
> 1. **上游 26.1 已经自己做了两件事**，脚本不再重复做，只报 `already`：
>    机型过滤（`device:MU3351` 已在过滤器里）和看板 DNS 改用 `jsonfilter`。
> 2. **上游 26.1 重写了 `mu300-hw` 的 `hw_bringup()`**（规则先、芯片后，加了 `ap_enabled_soon`）。
>    我们的「每步加超时」是套在它上面的，不是替换它——脚本改成**逐行**替换，23.2 和 26.1 都能命中。
>
> 还有一条与上游无关、但踩过一次的坑：**脚本文件自己的行尾必须是干净的 CRLF**。
> 如果它变成 `CR CR LF`，PowerShell 5.1 照样能解析，但每个 here-string 都会带上一个多余的 CR：
> 写出来的 `mu300-lancheck` 开头多一个空行（**shebang 不在第 0 字节，内核直接拒绝执行**）、
> 结尾多一个孤立 CR，而脚本的「已经打过补丁了吗」判断也会失效，于是同一段补丁被反复贴进去。
> 现在的脚本在 `Patch` 里把文本、匹配串、替换串里的 CR 全部去掉，第 18 步的门禁也改成
> **任何 CR 都不放过**、并额外检查文件是不是以换行开头。

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
| 19 | **灯光方案一致性门禁**（v50 方案跑在主线 `leds-aw9523b` 上 + 按键的 flash + 必须进 vendor-extra） | 半套方案**全是静默失效**：按键调一个 `mu300-led` 没有的子命令，只是打印用法然后什么也不做 |

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

原因很具体：**阿里云的 `releases/` 只同步到 `25.12.0-rc2`，没有本镜像用的 25.12.6**
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

完整记录（含 6.18/7.2/7.3 内核切换与回退）见 `docs/07-内核与按键与监管域.md`。

### 4.7 指示灯：网络灯按接入技术，WiFi 灯按频段

V50 面板上的彩灯是 I²C 总线 `i2c-3` 上的一颗 **Awinic AW9523B**
（`0x5b`，设备树 `/soc/ap-ahb/i2c@2270000/aw9523b_led@5b`）。

**驱动它的是上游主线内核的 `leds-aw9523b`**（上游 v2026.10.23.2 的
`port/drivers/leds/leds-aw9523b.c`），不是我们写的用户态 I²C 直控。设备上的实测：

```
aw9523b-led 3-005b: 4 LED groups, pin mask 0xffff
```

灯在 sysfs 里是**一类一个语义灯**，不是一组寄存器位：

| 类名 | max | 含义 |
|---|---|---|
| `v50:net1:{blue,red,white}` | 120 / 120 / 80 | **SIM 槽 1** 的网络灯组 |
| `v50:net2:{blue,red,white}` | 120 / 120 / 80 | **SIM 槽 0** 的网络灯组 |
| `v50:wifi:{blue,red,white}` | 120 / 120 / 80 | WiFi 灯组 |
| `aw9523b:pin0` … `pin15` | 80 / 120 | 原始 16 路（**DIM 寄存器序号，不是引脚号**） |

灯语（上游 `mu300-led` 的 v50 分支，`$V50_NET` 由 `/run/mu300/sim-slot` 决定）：

| 条件 | 灯 |
|---|---|
| 当前卡 **4G** | `v50:net2:blue` |
| 当前卡 **5G** | `v50:net2:white` |
| **无服务** | `v50:net2:red` |
| 热点 **5 GHz** | `v50:wifi:white` |
| 热点 **2.4 GHz** | `v50:wifi:blue` |

> **和旧文档不一样**：旧方案是「无外网=红 / 有网+5GHz=白 / 有网+2.4GHz=蓝」，红优先。
> 新方案里**红只表示无服务**，`data off`（调制解调器断开数据）是**灭**。
> 这不是我们改的语义，是**上游按 ZTE 原厂固件**定的（上游注释标为 FINDINGS 199，
> V50 B15 的 `NotificationManagerService.setNetLight`）：
> 网络灯说的是「这张卡现在在什么制式」，不是「有没有外网」。

我们相对上游只加了 `mu300-led flash`（按一下键闪 2 下作为「收到了」的回执，
次数由 `led.conf` 的 `LED_KEY_FLASH_COUNT` 决定）—— 因为切频段要 `wifi reload`，
颜色要等新信道回来才变，不先闪一下按键看起来就像没反应。

> ⚠️ **寄存器回读 ≠ 灯亮了**：灯光这类「给人看」的输出，回读只能用来**排除故障**
> （比如读芯片 ID `0x23`），不能用来**证明成功**。宣布「灯生效了」之前，
> 必须让人**用眼睛**看过面板。2026-10-25 已肉眼确认：面板上是**两盏白灯**
> （网络灯白 = 5G，WiFi 灯白 = 5GHz），与预期一致。
> 详见 `docs/08-灯光效果方案.md` 第〇节
> ——那里记着两次公开的结论更正。

完整实测记录（含寄存器布局、掩码换算、两次结论更正与退路）见 `docs/08-灯光效果方案.md`。

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

**默认启动项决定重启去哪。** 本仓库 2026-10-25 的实测配置把默认启动改成了 **Linux**
并**锁定**了 Linux 槽位，所以**在 OpenWrt 里点重启会回到 OpenWrt**，不是 Android。

设备上的实际状态（`mu300-next-boot status`）：

```
default boot: linux
locked: yes (Android only by hand)
failed boots in a row before Android: 5 (only while a new boot image is on trial)
boots since the last good one: 0
misc bootloader_control: 5f62000042434142010200009e00ef0000000000000000000000000088e09eaf
  slot a info: 9e  slot b info: ef  (prio | tries<<4 | successful<<7)
```

读法：`slot b`（Linux）prio=15 高于 `slot a`（Android）prio=14，两槽的 `successful` 位都是 1
→ **引导链进 Linux**。

> ⚠️ **「在 OpenWrt 里点重启必然回 Android」是旧版上游的语义，不是现在的。**
> 上游 v2026.10.23.2 的 `mu300-next-boot` 加了 `lock` / `unlock`：
> `lock` 把 Linux 槽的 `successful` 置 1，**引导链永不回退**，Android 只能手动切；
> `unlock` 才是把回退权交回去。旧版本里 `--rearm` 与「Switch to Android」会互相覆盖，
> 上游为此把 misc 的写操作串行化（`flock`）并让 `set_conf` 原子写。
>
> **两条兜底都要讲清楚**：
>
> 1. **写新的启动镜像会先解锁、试运行一次**（`--trial`）—— 万一新内核起不来，设备还能自己回来。
> 2. **「连续失败 N 次回 Android」只在试运行期间生效**。锁定之后这个计数不再起作用。
>    锁定状态记在 Linux 盘的 `.mu300/boot-lock`。
>
> 想回 Android 用上游的命令，不要直接改 misc：

```sh
mu300-next-boot status     # 先看当前状态
mu300-next-boot android    # 切回 Android（上游语义里这是永久的，不会自己回来）
mu300-next-boot unlock     # 交回回退权：之后连续失败 N 次就回 Android
mu300-next-boot lock       # 锁定：引导链永不回退
```

从 Android 侧切进 Linux（先看状态，再切）：

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
  07-内核与按键与监管域.md   6.18/7.2/7.3 内核切换（含 rollback）、5GHz 监管域根因、实体按键键码与映射
  08-灯光效果方案.md         灯语表、内核驱动方案、实测结果、两次公开的结论更正与退路
  09-OTA升级后恢复.md        上游 OTA 之后怎么把源、插件和按键补丁复原（实测手册）
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
  ubus-remote-test.py       PC 端：LuCI 的 ubus JSON-RPC 远程接入链路自检（4 件事）
plugins/
  ufi-tools-restart-to-openwrt.js   UFI-TOOLS 一键切换插件
patches/
  v50-changes-vs-upstream-v2026.10.26.1.patch  对上游 26.1 的完整改动（28 个文件，LF，可 git apply；新增脚本带可执行位）★
  v50-changes-vs-upstream-v2026.10.23.2.patch   对上游 23.2 的完整改动（旧基线，LF，可 git apply；新增脚本带可执行位）
  v50-buttons-vs-upstream-v2026.10.26.1.patch  只含按键与灯光 3 个文件（OTA 到 26.1 丢了按键移植时快补用）
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
- **面板彩灯只有主线内核点得着** —— 它是 I²C `i2c-3` 上的 AW9523B，Android 用 `aw9523b.ko` 驱动，
  该模块在本项目内核上装不了（vermagic 不匹配 + modversions）。**主线内核自带 `leds-aw9523b`**，
  所以 6.18 / 7.2 / 7.3 上灯是内核驱动的（`v50:net*` / `v50:wifi:*`），5.4 上一个都没有。
  这也是上游**只给 V50 主线内核**的原因之一。
- **纯 WPA3 不支持**（该 WiFi 驱动无 SAE）
- 6.18 内核偶发启动挂死（约 1/20）。**7.3 于 2026-10-25 实测正常，但样本只有一次**。
  V50 装不了 5.4（上游直接拒绝），所以没有更保守的退路，只能靠 `mu300-next-boot` 的失败计数

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
| **`apk add` 装不上，或 `apk update` 退出码 8** | 镜像站没有本镜像用的 25.12.6（阿里云就是这样） | 第 4 节 §4.3 |
| **看板「链路与流量」里 DNS 永远是 `--`** | 后端用逐行 sed 取多行 JSON 的数组，匹配不上 | 第 4 节 §4.1（补丁第 15 步） |
| 装了 `luci-app-commands` 却找不到菜单 | 它在 **系统 → Custom Commands**，不是顶级菜单 | `/cgi-bin/luci/admin/system/commands` |
| 改了 `openwrt/overlay/` 却毫无效果 | 预编译安装只认 vendor-extra 通道 | 4.2 |
| 装上去的脚本不执行 | 编码问题 | `tools\audit-repo-encoding.ps1` |
| 安装报 `ALREADY-MOUNTED loop32` | 上次挂载没卸载 | 06 手册第 6 节 |
| **安装向导在 V50 上拒绝 5.4 内核** | 上游只给 V50 主线内核（6.18 / 7.2 / 7.3） | 菜单 `1=5.4 / 2=6.18 / 3=7.2 / 4=7.3`，V50 的默认项是 2 |
| **装完重启没进 OpenWrt，回了 Android** | 写新启动镜像会先解锁试运行一次（`--trial`），失败计数只在试运行期间生效 | `mu300-next-boot status` 看 `default boot` 与 `locked` |
| 面板灯全黑（主线内核） | 灯在内核驱动上，先看驱动绑上没有 | `dmesg \| grep aw9523b` 应有 `aw9523b-led 3-005b: 4 LED groups` |
| **上游 OTA 之后 `apk` 什么都装不上** | 恢复出厂把 `/etc/apk/repositories.d/` 清空了 | `docs/09-OTA升级后恢复.md` 第 2 节 |
| **OTA 之后插件全没了、实体键也没反应** | OTA 用官方镜像整个换掉系统，我们打的补丁被抹了 | `docs/09-OTA升级后恢复.md` 第 3、4 节 |
| **`apk add mihomo-meta` 说文件冲突装不上** | 出厂的 `mihomo-alpha` 占着同一个二进制路径 | `docs/09-OTA升级后恢复.md` §3.4 |
| **`mu300-user-packages retry` 回一句 `running already` 就不动了** | 上次被强杀的运行留下了锁目录 | `docs/09-OTA升级后恢复.md` §5.1 |

---

## 11. 命名约定与设备身份 —— 为什么内部仍叫 mu300

**V50（`MU3351`）与 F50（`MU300`）是同一块板**：`ro.hardware` 都是 `ums9620_2h10_feimao`，
SoC 同为 UMS9620 / T760。所以上游对 F50 的支持**直接适用**，
`DEVICE=f50` 是**正确且经过实测**的路径 —— 补丁第 1 步只是让机型识别认下 `V50` / `MU3351`。

> **上游从 v2026.10.23.2 起原生支持 V50**：SIM mux（`port/drivers/misc/zte-v50-sim.c`）、
> 四板型卡映射（`rootfs/overlay/opt/mu300/lib/v50-card.sh`）、
> 面板灯的内核驱动（`port/drivers/leds/leds-aw9523b.c`）、
> 按设备树认出 V50 的 `mu300-device`（`v50_dt()` / `v50_fix()`）。
> 也就是说**上游自己也把这个设备叫 mu300** —— 下面那张「内部标识一律沿用 mu300」的表，
> 在上游那边是同样的选择，不是本项目发明的分叉。

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
