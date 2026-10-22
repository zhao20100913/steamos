# liuqin 移植细节

本文记录从 steamos-sheng 移植到 liuqin 的每一处设备差异与决策依据，供真机调试时回查。

## 设备层映射（sheng → liuqin）

底包同为 Valve Steam Frame（SteamOS holo / Deckard userspace，aarch64），SteamOS 侧修复
（屏蔽 Valve 分区挂载单元、partset/adbd gadget、repart/v4l2loopback/fpga、VARIANT_ID、
SDDM 直连 Plasma、gamescope 后端 drm、wifi 后端 wpa_supplicant、steam-health-check /
steamos-update / RUNSTEAM 替换）**设备无关，直接沿用**。真正改的是设备层：

| 功能 | sheng（SM8550） | liuqin（SM8475） | 移植动作 |
| --- | --- | --- | --- |
| 内核 | sm8550-mainline 7.2.6 | Linux 7.3 + liuqin 补丁 | `device-inputs` 用 liuqin-linux-kit 构建 |
| DTB | sm8550-xiaomi-sheng.dts | qcom/sm8475-xiaomi-liuqin.dtb | 随 boot.img 产出 |
| 启动 | 无 initramfs 直接挂根 | liuqin initramfs + root contract v2 | boot.img 直接用 liuqin-linux-kit 的 |
| 固件 | sheng-firmware | liuqin ROM 提取闭包 | `device/firmware` + `build-liuqin-firmware-prep.sh` |
| 触屏 | xiaomi-sheng-thp（NT36532E） | panel_novatek_nt36532 内核驱动 | 内核驱动已含，uinput 自动化在 device/input |
| 传感器 | sheng-sensors + adsprpcd-sensorspd | liuqin SSC 栈（iio-sensor-proxy/hexagonrpcd/ssc gate） | device/sensors + sensors-overlay |
| 设备认证 | sheng-devauth | liuqin 无 devauth，用 liuqin-mipps-auth | device/gnome-overlay |
| 键盘 | xiaomi-sheng-keyboard-helper | nanonsic 键盘（内核 caps-lock 补丁） | 内核补丁 0006 |
| 指纹 | libfprint 1.94.10 + fprintd 1.94.5 | liuqin 指纹栈（device/fingerprint） | 需自编 libfprint/fprintd |
| 电源 | xiaomi-charger-mode | liuqin-power-keyd + charger-mode | device/power-key + charger-mode |
| 音频 | cs35l43 UCM | liuqin HiFi UCM（Xiaomi-Pad-6-Pro-tplg.bin） | device/audio-topology |
| WLAN MAC | （sheng 无） | liuqin-wlan-mac.service | device/gnome-overlay |
| 存储守卫 | （sheng 无） | liuqin-gnome-storage-guard | **root contract 必需** |

## root contract v2 的完整要求

`device/boot/initramfs/init` 里 `storage_native_root_ok()` 在切根前逐项校验（失败即回退
RAM 只读，不切根）。graft 脚本必须满足：

**标记（内容与 sha256 固定）：**

| 文件 | 内容 | 校验 |
| --- | --- | --- |
| `/etc/liuqin-native-root` | `liuqin-native-root-v1` | sha256 + 22 字节 + 644 |
| `/etc/liuqin-storage-mode` | `persistent` | sha256 + 644 |
| `/etc/liuqin-root-profile` | `native-updatable` | sha256 + 644 |
| `/etc/liuqin-root-interface` | `liuqin-root-v2` | 644 |

**契约与内核身份：**

- `/etc/liuqin-native-root.contract` 与 `/usr/share/liuqin/kernels/<release>/boot.contract`
  必须一致（`root-interface-v2.sh` 校验）；`<release>` 必须等于 `uname -r`。
- `/usr/share/liuqin/kernels/<release>/modules.manifest`（sha256 清单）与
  `/usr/lib/modules/<release>/modules.dep` 存在且 mode 644。
- `/usr/lib/liuqin/root-interface-v2.sh`（initramfs 会 source）。

**可执行文件（mode 755）：** `/usr/lib/systemd/systemd`、`/usr/bin/hexagonrpcd`、
`/usr/libexec/iio-sensor-proxy`、`/usr/local/bin/busybox`、`/usr/local/bin/liuqin-shell`、
`/usr/local/sbin/liuqin-gnome-storage-guard`、`/usr/local/sbin/liuqin-gnome-usb-rescue`、
`/usr/local/sbin/liuqin-bt-public-addr`、`/usr/local/sbin/liuqin-wlan-mac`、
`/usr/libexec/liuqin-ssc-sample-gate`。

**常规文件（mode 644）与软链：** 见 `10-graft.sh` 第 3 节；`systemd --version` 在 chroot
内可执行是最后一道闸。

## 为何不用 sheng 的 pacman 设备包

sheng 的设备包来自 `code002-2/archlinux-sheng`（Arch 的 16 个 pacman 包）。liuqin 没有
对应的 Arch 打包仓库，其设备层在 liuqin-linux-kit 里以 `device/` 覆盖层 + `.deb`/`build-*`
脚本的形式存在。因此 liuqin 移植直接把这些**原始文件**（服务、脚本、udev 规则、固件、
传感器栈）graft 进 Arch 根，而不是转成 pacman 包。代价是这些文件不走 pacman 版本管理，
升级需重新构建镜像；好处是不必为 liuqin 维护一套 Arch 打包基础设施。

## 已知风险与待办

1. **root contract 的 exactness**：initramfs 校验极严（sha256、mode、readlink 目标逐项比对）。
   graft 脚本按 liuqin-linux-kit 的 `build-liuqin-custom-root.py` 语义铺标记，但真机必须
   验证 initramfs 日志里 `persistent root accepted: switching to LIUQIN_ROOT`。
2. **固件闭包完整性**：audio 调音 `Xiaomi-Pad-6-Pro-tplg.bin`、传感器 `sns_reg_version`
   与 config 需从 OS2.0.6.0.VMYCNXM ROM 完整提取；缺一个，root contract 或运行期功能都会失败。
3. **传感器/指纹栈**：SSC 传感器栈与指纹（libfprint/fprintd）需在 Arch 根里自编或
   直接复用 liuqin-linux-kit 的 ARM64 产物（注意 glibc ABI：liuqin-linux-kit 目标是
   Fedora/Ubuntu/Debian，Arch glibc 2.39 可能不兼容，需在底包 chroot 里重编）。
4. **Steam 客户端**：ARM64 Steam 客户端与 Gamepad UI 修复沿用 sheng，需实机验证登录/游戏模式。
