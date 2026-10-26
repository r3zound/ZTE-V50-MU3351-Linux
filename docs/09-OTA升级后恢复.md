# V50 OTA 升级后怎么把设备和插件恢复原样

> 2026-10-26 实测记录。设备在一次上游 OTA 之后软件源被清空、插件被卸载、我们自己的按键移植补丁被抹掉。
> 本文是**照着做就能复原**的操作手册，每一条都是当天在真机上跑过的。

---

## 0. 先搞清楚发生了什么

上游的 OTA（`mu300-update`）不是"升级几个文件"，而是**用官方镜像整个换掉系统**，再把你装过的东西装回去。
所以它天然会抹掉两类东西：

1. **你自己给系统打的补丁** —— 上游镜像里没有的文件，覆盖后就没了。
2. **你自己配的软件源** —— `/etc/apk/repositories.d/` 属于系统配置，不在你的包列表里，不会被带回来。

而"恢复出厂设置"会再补一刀：它连你手动加过的源文件也一起清掉。

设备上的证据在 `/etc/mu300/update-report`：

```
==== openwrt-luci: v2026.10.23.3 -> v2026.10.26.1, 2026-10-26 02:37 ====
Everything you added to the system was carried over: 3658 files, 157 MB.
...
699 files of packages are not carried: they come with their packages.
Packages installed on the device:
  geoview luci-app-commands ... xray-core
  The new system does not have them: its first boot installs them again once the device is online
  Their settings are set aside until they are back, so that they cannot act without them:
    /etc/config/passwall2_server -> /etc/mu300/orphaned-config/etc/config/passwall2_server (luci-app-passwall2)
    /etc/config/nikki -> /etc/mu300/orphaned-config/etc/config/nikki (nikki)
```

于是要复原三样东西：**软件源**、**插件**、**我们自己的补丁**。下面按这个顺序做。

---

## 1. 先诊断，别急着装

三条命令就能看清全貌（设备上 root shell）：

```sh
cat /etc/apk/repositories.d/distfeeds.list      # 官方源：出厂后是空的
cat /etc/apk/repositories.d/customfeeds.list     # 自定义源： Nikki / PassWall
ls -l /etc/apk/keys/                             # 签名钥匙：少一个就装不上对应源的包
cat /etc/mu300/user-packages/wanted              # OTA 记下的、你装过的包
cat /etc/mu300/user-packages/state               # 上次装到哪一步了
ls -lR /etc/mu300/orphaned-config/               # 被搁置的配置
```

再确认我们的补丁是不是真没了：

```sh
ls -l /opt/mu300/bin/mu300-buttons /opt/mu300/bin/mu300-led /etc/init.d/mu300-buttons
```

**判据**（2026-10-26 实测）：

| 文件大小 | 含义 |
|---|---|
| `mu300-buttons` = 7689 B | 上游 26.1 原版 —— **补丁没了** |
| `mu300-buttons` = 9350 B | 我们的 23.2 补丁版 |

上游 26.1 改进了 `mu300-buttons`（`hotspot_set` 现在会真的写 `wireless.disabled`），所以**绝对不能拿 23.2 的旧版整个覆盖回去**——那会把上游的改进也一起抹掉。正确做法见第 4 节。

---

## 2. 恢复软件源

### 2.1 官方源：清华 TUNA

```sh
cat > /etc/apk/repositories.d/distfeeds.list <<'EOF'
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.6/targets/armsr/armv8/packages/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.6/packages/aarch64_generic/base/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.6/targets/armsr/armv8/kmods/6.12.112-1-67e205f26d0458c4d12f1fd315216398/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.6/packages/aarch64_generic/luci/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.6/packages/aarch64_generic/packages/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.6/packages/aarch64_generic/routing/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.6/packages/aarch64_generic/telephony/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.6/packages/aarch64_generic/video/packages.adb
EOF
```

**换主机名，不换版本段。** `25.12.6` 和 kmods 那段 `6.12.112-1-67e205f...` 都是发行版的标识，跟着发行版走，改了就指到另一套 userspace 去了。

> **一个容易搞反的点**：kmods 路径里的 `6.12.112` 是 **OpenWrt 发行版的内核版本**，不是设备正在跑的内核（那是 mu300 的主线 7.3.0）。
> 实测：设备 `/lib/modules/` 下同时存在 `5.4.254-gb50db5b6224c`（基础镜像）、`6.12.112`（官方源 kmod 包落点，13 个文件）、`7.3.0`（真正在跑的，3059 个模块）。
> 而 Nikki 透明代理要用的三个东西是**直接编进 7.3.0 内核**的，不是模块：
> `CONFIG_TUN=y`、`CONFIG_NFT_TPROXY=y`、`CONFIG_NFT_SOCKET=y`。
> 所以官方源那几个 `kmod-*` 包在这台设备上装了也用不上（模块落在 `/lib/modules/6.12.112/`，7.3.0 不会去那儿找），**但也不碍事**，装上就行。

### 2.2 自定义源：Nikki + PassWall

```sh
cat > /etc/apk/repositories.d/customfeeds.list <<'EOF'
https://nikkinikki.pages.dev/openwrt-25.12/aarch64_generic/nikki/packages.adb
https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-25.12/aarch64_generic/passwall_packages/packages.adb
https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-25.12/aarch64_generic/passwall_luci/packages.adb
https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-25.12/aarch64_generic/passwall2/packages.adb
EOF
```

### 2.3 签名钥匙

PassWall 源的包是自签名的，**没有对应公钥就会拒绝安装**（报签名不匹配，不是"找不到包"）。
从刷机前的备份里取：

```sh
tar xf backup/mu300root-pre-7.3-20261025.tar -C /tmp ./etc/apk/keys/openwrt-passwall-build.pem
cp /tmp/etc/apk/keys/openwrt-passwall-build.pem /etc/apk/keys/
```

（`nikki.pem` 和 `openwrt-25.12.pem` 出厂就带着，不用管。）

### 2.4 验证

```sh
apk update        # rc=0，实测 11193 个包可用
```

---

## 3. 恢复插件

### 3.1 目标清单

`/etc/mu300/user-packages/wanted` 里就是你要恢复的东西，实测 **26 个**：

```
geoview luci-app-commands luci-app-frpc luci-app-nikki luci-app-nlbwmon
luci-app-passwall2 luci-app-run luci-app-samba4 luci-app-tailscale-community
luci-i18n-{commands,frpc,nikki,nlbwmon,passwall2,samba4,tailscale-community}-*
mihomo-meta nikki tcping unzip usbutils xray-core
```

`geoview` 和 `tcping` **就在 PassWall 源里**，不用去别处找。

### 3.2 先关掉会抢锁的服务

`mu300-user-packages` 服务自己就在跑 `apk add`，两个 apk 同时跑会互相抢数据库锁：

```sh
/etc/init.d/mu300-user-packages stop
/etc/init.d/mu300-user-packages disable
```

### 3.3 一次装完源里的包

```sh
apk add \
  geoview tcping unzip usbutils xray-core \
  luci-app-commands luci-app-frpc luci-app-nlbwmon luci-app-samba4 luci-app-tailscale-community \
  luci-i18n-commands-tr luci-i18n-commands-zh-cn \
  luci-i18n-frpc-tr luci-i18n-frpc-zh-cn \
  luci-i18n-nikki-zh-cn \
  luci-i18n-nlbwmon-tr luci-i18n-nlbwmon-zh-cn \
  luci-i18n-passwall2-zh-cn \
  luci-i18n-samba4-tr luci-i18n-samba4-zh-cn \
  luci-i18n-tailscale-community-zh-cn \
  luci-app-passwall2
```

### 3.4 mihomo 的文件冲突（必踩）

设备出厂带的是 `mihomo-alpha-2026.08.16`，它占着 `/usr/libexec/mihomo`；
而你要装的 `mihomo-meta` 要的是**同一个路径**。`apk` 会因为冲突不让你装。

而且 `mihomo-meta` 是个 **meta 包**：它的安装脚本会去下载 57 MB 的二进制。
V50 走 4G 到 `nikkinikki.pages.dev` 实测只有 3 KB/s —— 那是十几个小时。

**做法**：用本地 apk 装（跳过脚本），二进制自己放。

```sh
# 1) 删掉占位的
apk del mihomo-alpha

# 2) 本地 apk 装 meta 包，跳过会下载 57MB 的安装脚本
apk add --no-scripts --allow-untrusted /data/local/tmp/mihomo-meta-1.19.32.apk

# 3) 二进制自己放（和 meta 包同一个版本 1.19.32）
cp /data/local/tmp/mihomo-bin /usr/libexec/mihomo
chmod 755 /usr/libexec/mihomo
```

装完确认：

```sh
apk info -W /usr/libexec/mihomo      # 应为 mihomo-meta-1.19.32
/usr/libexec/mihomo -v                # Mihomo Meta v1.19.32 linux arm64
```

> `mihomo-meta` 提供 `mihomo=1.19.32` 这个**虚拟包名**，而 `nikki` 依赖的正是 `mihomo`。
> 所以 `apk del mihomo-alpha` 报的"not removed due to luci-app-nikki"不是问题：装了 meta 包之后 nikki 的依赖链是完整的。

### 3.5 源里没有的包：`luci-app-run`

它只在自己的 GitHub release 里（`wukongdaily/luci-app-run`，tag `v2026.06.27`），任何源都没有：

```sh
apk add --allow-untrusted /data/local/tmp/luci-app-run-1.0.0-r9.apk
```

### 3.6 大包走本地下载，别在 4G 上死磕

**实测**：`xray-core` / `v2ray-geoip` / `v2ray-geosite` 这三个从 sourceforge 直下，
4G 链路上 wget 连着报 `error 4`（Connection aborted），试了三遍都断在最后一步。

解法：**在电脑上用代理下好，再 push 上去**。

```sh
# 电脑上（Windows，curl 走代理）
curl.exe -sL -o xray-core-26.10.21-r1.apk "https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-25.12/aarch64_generic/passwall_packages/xray-core-26.10.21-r1.apk/download"
# 推上去，再本地装
adb push xray-core-26.10.21-r1.apk /data/local/tmp/
apk add --allow-untrusted /data/local/tmp/xray-core-26.10.21-r1.apk
```

`apk` 会拿索引里的校验和自己核对，所以本地装的包和源里的包等价。

### 3.7 核对

```sh
for p in $(cat /etc/mu300/user-packages/wanted); do
    apk info -e "$p" >/dev/null 2>&1 && echo "OK      $p" || echo "MISSING $p"
done
apk list --installed | wc -l        # 实测 323
```

---

## 4. 重放我们自己的按键/灯光补丁

### 4.1 原则：只重放增量，绝不覆盖上游

上游 26.1 改进了 `mu300-buttons`，拿 23.2 的旧版盖回去等于把上游的改进也抹了。
正确做法是**算出我们的增量，再叠到 26.1 上**。

我们的增量一共 5 处（`diff 原版23.2 → 我们的23.2` 得到）：

| # | 位置 | 内容 |
|---|---|---|
| 1 | 文件头注释 | 补两行 function key 的说明 |
| 2 | `KEY_WIFI=138` 之后 | `KEY_FN=464` 及其注释（V50 唯一那颗键） |
| 3 | `DEADLINE=` 之后 | `HOLD=${MU300_BUTTONS_HOLD:-…}`（V50 长按 10 秒，其它机器 3 秒） |
| 4 | `mu300-keys -l 3000` | 改成 `mu300-keys -l "$HOLD"` |
| 5 | `case` 分支 | `"$KEY_FN short")` / `"$KEY_FN long")` 两个分支 |

叠完之后**上游 26.1 的东西必须还在**，这是验收点：

```sh
grep -F 'wireless.@wifi-device[0].disabled=1' /opt/mu300/bin/mu300-buttons   # 上游 26.1 的 hotspot_set 改进
```

### 4.2 三个文件

| 设备路径 | 内容 |
|---|---|
| `/opt/mu300/bin/mu300-buttons` | 按键处理脚本（上面 5 处增量） |
| `/opt/mu300/bin/mu300-led` | 灯光脚本（新增 `flash` 子命令：按一下闪一下） |
| `/etc/init.d/mu300-buttons` | init 脚本（新增 `stop_service()`） |

`/etc/init.d/mu300-buttons` 的 `stop_service()` 不是锦上添花：
没有它，**每次重启都会多出一个 `mu300-keys` 读键进程**，一个键按两遍 —— 切频段切两次等于没切，键看起来是死的，但其它它控制的东西都正常。
2026-10-10 实测：重启一次后有两个读键进程。

### 4.3 部署

```sh
# 备份
mkdir -p /data/local/tmp/v50-backup
cp -p /opt/mu300/bin/mu300-buttons /data/local/tmp/v50-backup/mu300-buttons.before
cp -p /opt/mu300/bin/mu300-led     /data/local/tmp/v50-backup/mu300-led.before
cp -p /etc/init.d/mu300-buttons   /data/local/tmp/v50-backup/init.d-mu300-buttons.before

# 覆盖
cp /data/local/tmp/v50-patch/mu300-buttons        /opt/mu300/bin/mu300-buttons
cp /data/local/tmp/v50-patch/mu300-led            /opt/mu300/bin/mu300-led
cp /data/local/tmp/v50-patch/init.d-mu300-buttons /etc/init.d/mu300-buttons
chmod 755 /opt/mu300/bin/mu300-buttons /opt/mu300/bin/mu300-led /etc/init.d/mu300-buttons

# 语法检查 + 重启
sh -n /opt/mu300/bin/mu300-buttons && sh -n /opt/mu300/bin/mu300-led && sh -n /etc/init.d/mu300-buttons
/etc/init.d/mu300-buttons stop && sleep 2 && /etc/init.d/mu300-buttons start && sleep 3
```

### 4.4 验收

```sh
ps w | grep mu300-keys | grep -v grep | wc -l          # 必须是 1
ps w | grep mu300-keys                                 # 应显示 mu300-keys -l 10000 -t 5
ls -d /proc/device-tree/gpio-keys/key-function          # 存在 → HOLD 自动选 10000
```

`-l 10000` 就说明长按 10 秒被正确识别了（3 秒是上游其它机器的默认值）。

**按键的实际效果要靠眼睛确认**：短按切频段并闪一下，长按 10 秒重启。
脚本能证明的是"它会去做"，不是"它做了"——灯和切频段都得你自己看着。

---

## 5. 配置和记录：交给上游工具，别手工搬

上游自带 `mu300-user-packages`，它知道哪些配置属于哪个包、每个服务升级前是不是开着的。
**别手工 `cp` 配置，手工搬会漏掉服务启用状态的恢复。**

```sh
mu300-user-packages retry
```

它做四件事：把已经装上的包记进 `done`、把被搁置的配置搬回 `/etc/config`、按升级前的记录恢复服务启用状态、把 `state` 置成 `done`。

实测输出：

```
nikki: its settings are back (/etc/config/nikki)
26 of 26 packages installed on the device before the update are back
```

搬回来的是**你原来那份**（实测 6143 字节、10 月 20 日的修改时间），不是新装 nikki 时生成的那份默认值。

### 5.1 陈旧锁

`mu300-user-packages` 用 `mkdir` 当互斥锁。进程被强杀（比如装包超时后 `kill -9`）会把锁目录留下，
之后**每一次** `run` / `retry` 都会直接回一句 `mu300-user-packages is running already` 然后什么都不做。

```sh
ps w | grep mu300-user-packages | grep -v grep     # 确认没有进程在跑
rmdir /var/run/mu300-user-packages.lock             # 锁目录在 /var/run，不是 /run 之外的路径
mu300-user-packages retry
```

判据：锁目录的时间戳如果停在很久以前、而没有进程在跑，那就是陈旧锁。

---

## 6. 完整验收清单

```sh
# 1. 包
for p in $(cat /etc/mu300/user-packages/wanted); do
    apk info -e "$p" >/dev/null 2>&1 && echo "OK      $p" || echo "MISSING $p"
done
apk list --installed | wc -l

# 2. 源
apk update; echo "rc=$?"

# 3. 配置
ls -l /etc/config/nikki /etc/config/passwall2_server
ls -lR /etc/mu300/orphaned-config/          # 应该已经空了

# 4. 记录
mu300-user-packages status                 # 应为 "26 of 26 ... are back"，state: done

# 5. 二进制
/usr/libexec/mihomo -v
/usr/bin/xray version

# 6. 按键补丁
ps w | grep mu300-keys | grep -v grep | wc -l     # 1
for pat in 'KEY_FN=464' 'mu300-keys -l "$HOLD" -t 5' '"$KEY_FN short")' '"$KEY_FN long")'; do
    grep -qF "$pat" /opt/mu300/bin/mu300-buttons && echo "OK $pat" || echo "MISSING $pat"
done
grep -qF 'flash "*)' /opt/mu300/bin/mu300-led && echo "OK mu300-led flash"
grep -qF 'stop_service()' /etc/init.d/mu300-buttons && echo "OK stop_service()"

# 7. 启动方式
mu300-next-boot status                    # default boot: linux / locked: yes
```

---

## 7. 这次踩到的坑

| 坑 | 现象 | 对策 |
|---|---|---|
| 源被恢复出厂清空 | `apk add` 说找不到包，但 `apk update` 是空的 | 恢复 `repositories.d/` 两个文件 + 签名钥匙 |
| PassWall 源缺公钥 | 报签名不匹配（不是"包不存在"） | 从备份取 `openwrt-passwall-build.pem` |
| `mihomo-alpha` vs `mihomo-meta` 抢同一路径 | `apk add mihomo-meta` 装不上 | 先 `apk del mihomo-alpha`，再用本地 apk + `--no-scripts` 装 |
| meta 包的安装脚本下 57 MB | 4G 上 3 KB/s，要十几个小时 | `--no-scripts` 跳过脚本，二进制手工放 |
| 4G 下载大包被掐断 | `wget: exited with error 4` | 电脑上带代理下好再 push |
| `luci-app-run` 任何源都没有 | `apk add` 说 no such package | 用它自己的 GitHub release 的 apk |
| `mu300-user-packages` 的陈旧锁 | `running already`，什么都不做 | 确认没进程后 `rmdir` 锁目录 |
| `apk` 抢锁 | `Unable to lock database` | 先停 `mu300-user-packages` 服务；有 apk 进程占着就按 PID `kill -9`（`pkill` 不行） |

---

## 8. 26.1 基线上的补丁现状

- `patches/v50-buttons-vs-upstream-v2026.10.26.1.patch`：**已经生成并验证**，就是第 4 节那三个文件。
  在一份原版 26.1 上 `git apply --check` 通过、`git apply` 通过，打完之后的三个文件与设备上跑的**逐字节一致**（sha256 对得上），可执行位 100755 保留。
- 完整的 28 文件补丁 `patches/v50-changes-vs-upstream-v2026.10.23.2.patch`：
  实测在原版 **26.1** 上 `git apply --check` 只有**一个文件**过不去 —— `openwrt/overlay/etc/init.d/mu300-hw`，
  因为上游 26.1 重写了 `hw_bringup()`（先加载监管域再起芯片、AP 已就绪就跳过 down/up），
  和我们的超时包装增量（`bringup_step`）改的是同一批行。其余 27 个文件都能干净应用（含带 offset 的自动重定位）。
  换句话说：**整套补丁重做 26.1 版只需要手工 rebase 这一个文件。**
