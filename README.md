# SteamOS for liuqin（小米平板 6 Pro）

以 **Steam Frame 官方恢复镜像**（SteamOS holo / Deckard userspace，aarch64）为底包，注入
**liuqin（小米平板 6 Pro，SM8475）** 的内核、固件与设备层，产出可 fastboot 刷入的
`rootfs.img` + `boot.img`。

本仓库是 [steamos-sheng](https://github.com/code002-2/steamos-sheng) 的 liuqin 移植：
**底包与 SteamOS 侧修复完全一致**，仅把 sheng（Pad 6S Pro / SM8550）的设备层换成
liuqin（Pad 6 Pro / SM8475）的设备层。内核、设备服务、固件来源来自
[liuqin-linux-kit](https://github.com/wkai343/liuqin-linux-kit)（衍生自
[yzddmr6/linux-sm8450-liuqin](https://github.com/yzddmr6/linux-sm8450-liuqin)）。

## 与 steamos-sheng 的差异

| 项 | sheng（SM8550 / Pad 6S Pro） | liuqin（SM8475 / Pad 6 Pro） |
| --- | --- | --- |
| 内核 | `ianchb/sm8550-mainline` 7.2.6 | Linux 7.3 + liuqin 补丁（liuqin-linux-kit `build/kernel/source.json`） |
| 启动 | **无 initramfs**，内核直接挂根（EXT4/UFS 内置） | **带 initramfs**（liuqin boot.img，含 storage guard / root contract v2） |
| 设备包 | archlinux-sheng 的 pacman 包（16 个） | liuqin-linux-kit 的 `device/` 覆盖层 + 固件闭包（直接 graft） |
| 固件 | `ianchb/sheng-firmware` | liuqin ROM 提取（`device/firmware` + audio 调音 + 传感器配置） |
| 触屏 | `xiaomi-sheng-thp`（NT36532E 用户态 daemon） | `panel_novatek_nt36532` 内核驱动 + uinput automation |
| 根分区 | `PARTLABEL=userdata` / `linux` | `PARTLABEL=linux_root`（回退 `userdata`），`LABEL=LIUQIN_ROOT` 权威 |
| root 校验 | 无 | **liuqin root contract v2**（见下文） |

## 关键：liuqin root contract v2

liuqin 的 boot.img 带 initramfs，切根前会**严格校验**根分区（`device/boot/initramfs/init`
+ `root-interface-v2.sh`）。SteamOS userspace 铺完后必须满足这套契约，否则内核拒绝挂根：

- 标记：`/etc/liuqin-native-root`（`liuqin-native-root-v1`）、`/etc/liuqin-storage-mode`
  （`persistent`）、`/etc/liuqin-root-profile`（`native-updatable`）、
  `/etc/liuqin-root-interface`（`liuqin-root-v2`）。
- 契约：`/etc/liuqin-native-root.contract` 与 `/usr/share/liuqin/kernels/<release>/boot.contract`
  、`modules.manifest`、`/usr/lib/modules/<release>/modules.dep` 必须与 boot.img 同源。
- 服务：`liuqin-gnome-storage-guard`（basic.target.requires）、`liuqin-gnome-usb-rescue`
  （multi-user.wants）、`liuqin-backlight-default`（graphical.wants）等。
- 固件路径：`/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin`、传感器
  `/usr/share/qcom/sm8450/Xiaomi/liuqin/sensors/sns_reg_version`。

`scripts/in-chroot/10-graft.sh` 会把这些从 liuqin-linux-kit 的产物里铺进根分区。**boot.img
与模块必须来自同一次 liuqin-linux-kit 构建**（`04-verify-kernel-match.sh` 会做闸）。

## 构建（GitHub Actions）

workflow `rootfs.yml`（workflow_dispatch）分两段：

1. **device-inputs**（x86_64）：检出 liuqin-linux-kit，Devbox 构建内核/模块/boot.img/固件，
   打包成 `liuqin-inputs.tar.gz`。
2. **assemble**（ARM）：下载 Steam Frame → 铺 userspace → chroot 执行 graft → 收尾 →
   校验 → 上传 `rootfs.img` + `boot.img`。

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `frame_image_url` | Steam Frame 官方恢复镜像 | 底包地址 |
| `rootfs_size` | `14G` | rootfs.img 初始大小下限（按底包用量自动放大） |
| `shrink_image` | `true` | `e2fsck` + `resize2fs -M` 收缩 |
| `kernel_release` | 空 | liuqin 内核 release；空则从 `kernel.release` 取 |
| `wifi_ssid` / `wifi_password` | 空 | 开机自动连的 WiFi（仅构建输入） |
| `ssh_pubkey` | 空 | root 的 authorized_keys |
| `root_password` | `123456` | root 密码（SSH 用） |

## 刷入

```sh
fastboot flash boot_b  boot.img
fastboot flash userdata rootfs.img   # 单系统（userdata 布局）
```

双系统（`linux_root` 分区）布局需先用 liuqin-linux-kit 的安装器写好分区表，再刷
`rootfs.img` 到 `linux_root`；本工作流默认单系统 `userdata` 路径（boot.img 的 initramfs
会回退到 `userdata`，只要 `LABEL=LIUQIN_ROOT` 正确）。

## 目录结构

```text
scripts/host/                  取底包 / 铺镜像 / 收尾 / 校验（设备无关，抄自 steamos-sheng）
scripts/in-chroot/10-graft.sh  liuqin 设备层注入 + root contract + SteamOS 修复（核心）
.github/workflows/rootfs.yml   device-inputs → assemble 两段构建
docs/PORT.md                   liuqin↔sheng 映射与移植细节
```

## 许可与第三方组件

- SteamOS / Steam Frame userspace：Valve Corporation（仅作底包）
- 内核 / 设备层 / boot.img：liuqin-linux-kit（Linux 7.3 + liuqin 补丁，衍生自
  yzddmr6/linux-sm8450-liuqin）
- 底包与 SteamOS 修复脚本结构：steamos-sheng（code002-2）及 MaSieS4Fun/SteamOS-ARM-SM8550
- 本仓库脚本：见各文件头 SPDX

## 状态与验收

本移植是**构建/移植脚手架**，尚未真机验收。已知待验证/风险：

- Steam Frame 是 Arch（glibc 2.39），liuqin 内核 7.3 与 liuqin 设备层需在真机确认
  `root contract v2` 校验全部通过（尤其 `systemd --version` 在 chroot 内可执行）。
- 传感器栈（SSC / iio-sensor-proxy / hexagonrpcd）与指纹栈的固件闭包需从 ROM 完整提取。
- 显示/Wi-Fi/HiFi 音频/自动旋转/磁吸键盘/电池/指纹等按 liuqin-linux-kit 的
  [硬件说明](https://github.com/wkai343/liuqin-linux-kit/blob/main/docs/HARDWARE.md) 口径逐项验收。
- Steam 客户端（ARM64）下载与 Gamepad UI 修复沿用 sheng，Steam 登录/游戏模式仍需实机验证。
