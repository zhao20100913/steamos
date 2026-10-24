#!/usr/bin/env bash
# 10-graft.sh —— 在（已铺好 Steam Frame userspace 的）镜像 chroot 内注入 liuqin 设备层
#
# 与 steamos-sheng 的关系：
#   底包同为 Valve Steam Frame（SteamOS holo / Deckard userspace, aarch64），
#   SteamOS 侧修复（屏蔽 Valve 分区挂载单元、VARIANT_ID、SDDM 直连 Plasma、
#   gamescope 后端、Steam 客户端、wifi 后端）基本设备无关，沿用 sheng 的结论。
#   设备层差异是核心：sheng 用 archlinux-sheng 的 pacman 包 + sm8550-mainline 内核
#   （无 initramfs，内核直接挂根）；liuqin 用 liuqin-linux-kit 的 SM8475 内核 +
#   **带 initramfs 的 boot.img**，且 initramfs 会按「liuqin root contract v2」严格
#   校验根分区（LABEL=LIUQIN_ROOT、native-root 标记、boot.contract、modules.manifest、
#   一组项目自有服务/固件路径）。因此本脚本除了铺 SteamOS，还必须把 liuqin 的
#   内核模块、固件、设备服务与 root contract 一次性铺进根分区，否则内核会拒绝挂根。
#
# 输入（由 workflow 在 chroot 前挂载/拷贝到 /tmp/liuqin-inputs/）：
#   kernel/          liuqin 内核模块树 usr/lib/modules/<release>/... + boot.contract +
#                    modules.manifest + Image + kernel.release
#   firmware/        固件闭包（liuqin-linux-kit 的 device/firmware 闭包 + ROM 提取）
#   overlay/         设备 overlay（device/gnome-overlay 内容 + device/ 下服务/脚本）
#   sensors/         传感器栈（hexagonrpcd、iio-sensor-proxy、ssc sample gate 等）
#   audio/           Xiaomi-Pad-6-Pro-tplg.bin 等 HiFi 调音
#   root/            etc/liuqin-native-root、etc/liuqin-storage-mode、
#                    etc/liuqin-root-profile、root-interface-v2.sh、busybox、liuqin-shell
#   contract/        native-root.contract（boot.contract 原文）
#
# 环境变量（workflow 传入）：PARTLABEL、HOSTNAME_OVERRIDE、WIFI_SSID、WIFI_PSK、
#   ROOT_PW、SSH_PUBKEY、KERNEL_RELEASE。
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

PARTLABEL="${PARTLABEL:-linux_root}"
INPUTS=/tmp/liuqin-inputs
KREL="${KERNEL_RELEASE:-}"

# ---------------------------------------------------------------------------
# 0) 基本自检
# ---------------------------------------------------------------------------
[ -x /sbin/init ] || die "找不到 /sbin/init（缺 systemd？）"
[ -d "$INPUTS" ] || die "缺少 liuqin 输入目录 $INPUTS（workflow 没把 liuqin-linux-kit 产物拷进来）"
command -v pacman >/dev/null 2>&1 || die "这不是 Arch/SteamOS 根（缺 pacman）"

# ---------------------------------------------------------------------------
# 1) 撤掉 Frame 的内核生成钩子 + 内核 + 固件（我们换 liuqin 的，无 initramfs 直接挂根）
# ---------------------------------------------------------------------------
log "撤掉 Frame 的内核生成钩子与 preset（必须在任何 pacman 事务之前）"
rm -f /usr/lib/tmpfiles.d/steamos-mkinitcpio.conf \
      /etc/mkinitcpio.d/*.preset \
      /usr/lib/kernel/install.d/* 2>/dev/null || true

log "移除 Frame 自带内核与固件包（换成 liuqin 的）"
_kernels=()
while IFS= read -r _k; do [ -n "$_k" ] && _kernels+=("$_k"); done < \
  <(pacman -Qq 2>/dev/null | grep -E '^(linux|linux-|kernel|steamos-kernel)' || true)
[ "${#_kernels[@]}" -eq 0 ] || pacman -Rdd --noconfirm --color never "${_kernels[@]}" 2>/dev/null || true
_fw=()
while IFS= read -r _f; do [ -n "$_f" ] && _fw+=("$_f"); done < \
  <(pacman -Qq 2>/dev/null | grep -iE 'firmware' || true)
[ "${#_fw[@]}" -eq 0 ] || pacman -Rdd --noconfirm --color never "${_fw[@]}" 2>/dev/null || true
rm -rf /boot/* /usr/lib/modules/* 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2) 铺 liuqin 内核模块 + 固件 + 设备层（直接拷贝，不走 pacman）
# ---------------------------------------------------------------------------
log "铺 liuqin 内核模块树"
[ -n "$KREL" ] || KREL="$(cat "$INPUTS/kernel/kernel.release" 2>/dev/null | head -1 || true)"
[ -n "$KREL" ] || die "拿不到内核 release（KERNEL_RELEASE / kernel/kernel.release）"
mkdir -p /usr/lib/modules
cp -a "$INPUTS/kernel/usr/lib/modules/$KREL" /usr/lib/modules/ 2>/dev/null \
  || cp -a "$INPUTS/kernel/modules/$KREL" /usr/lib/modules/ 2>/dev/null \
  || die "内核模块树缺失：$INPUTS/kernel（期望 usr/lib/modules/$KREL 或 modules/$KREL）"
[ -f "/usr/lib/modules/$KREL/modules.dep" ] || die "modules.dep 未生成（depmod 没跑）"
if [ -f "$INPUTS/kernel/Image" ]; then
  install -D -m 0644 "$INPUTS/kernel/Image" "/boot/vmlinuz-$KREL"
fi

log "铺 liuqin 固件闭包（device/firmware 以 usr/lib 为根，铺到 /）"
if [ -d "$INPUTS/firmware" ]; then
  cp -a "$INPUTS/firmware/." / || warn "固件闭包拷贝失败，继续"
fi
if [ -d "$INPUTS/audio" ]; then
  install -D -m 0644 "$INPUTS/audio/Xiaomi-Pad-6-Pro-tplg.bin" \
    /usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin 2>/dev/null || \
    warn "缺 Xiaomi-Pad-6-Pro-tplg.bin（HiFi 音频拓扑）"
fi

log "铺 liuqin 设备 overlay（board-overlay：板级服务）"
if [ -d "$INPUTS/overlay" ]; then
  cp -a "$INPUTS/overlay/." / || die "设备 overlay 拷贝失败"
fi

# 可选：gnome-overlay（power-keyd / 相机 / 电源菜单等桌面集成）
if [ -d "$INPUTS/gnome-overlay" ]; then
  cp -a "$INPUTS/gnome-overlay/." / || warn "gnome-overlay 拷贝失败（可选）"
fi

log "铺 liuqin 传感器栈配置（sensors-overlay）"
if [ -d "$INPUTS/sensors" ]; then
  cp -a "$INPUTS/sensors/." / || die "传感器栈拷贝失败"
fi

# iio-sensor-proxy：sensor-stack.tar 里在 /usr/local/libexec/liuqin-iio-sensor-proxy，
# root contract 要的是 /usr/libexec/iio-sensor-proxy（DEB 打包阶段才会搬，这里手动补上）
if [ -x /usr/local/libexec/liuqin-iio-sensor-proxy ] && [ ! -e /usr/libexec/iio-sensor-proxy ]; then
  install -D -m 0755 /usr/local/libexec/liuqin-iio-sensor-proxy /usr/libexec/iio-sensor-proxy
  log "已把 iio-sensor-proxy 复制到 /usr/libexec/iio-sensor-proxy"
fi

log "铺 liuqin 根契约与救援工具"
if [ -d "$INPUTS/root" ]; then cp -a "$INPUTS/root/." / || die "根契约拷贝失败"; fi
if [ -d "$INPUTS/contract" ]; then
  install -D -m 0644 "$INPUTS/contract/native-root.contract" /etc/liuqin-native-root.contract 2>/dev/null || \
    warn "缺 native-root.contract"
fi
if [ -f "$INPUTS/kernel/boot.contract" ]; then
  install -D -m 0644 "$INPUTS/kernel/boot.contract" "/usr/share/liuqin/kernels/$KREL/boot.contract"
fi
if [ -f "$INPUTS/kernel/modules.manifest" ]; then
  install -D -m 0644 "$INPUTS/kernel/modules.manifest" "/usr/share/liuqin/kernels/$KREL/modules.manifest"
fi

# root-interface-v2.sh 是 initramfs 里 source 的内核 helper，必须落在 /usr/lib/liuqin/
if [ -f /usr/lib/liuqin/root-interface-v2.sh ]; then
  :
elif [ -f "$INPUTS/root/root-interface-v2.sh" ]; then
  install -D -m 0644 "$INPUTS/root/root-interface-v2.sh" /usr/lib/liuqin/root-interface-v2.sh
else
  warn "缺 root-interface-v2.sh（initramfs 会 source 它；boot.contract 校验会失败）"
fi

# ---------------------------------------------------------------------------
# 3) root contract 标记（内容必须与 initramfs 里固定的 sha256 完全一致）
# ---------------------------------------------------------------------------
log "写 root contract 标记（内容已由 liuqin-linux-kit 固定）"
[ -f /etc/liuqin-native-root ] || printf 'liuqin-native-root-v1\n' > /etc/liuqin-native-root
chmod 644 /etc/liuqin-native-root
[ -f /etc/liuqin-storage-mode ] || printf 'persistent\n' > /etc/liuqin-storage-mode
chmod 644 /etc/liuqin-storage-mode
[ -f /etc/liuqin-root-profile ] || printf 'native-updatable\n' > /etc/liuqin-root-profile
chmod 644 /etc/liuqin-root-profile
[ -f /etc/liuqin-root-interface ] || printf 'liuqin-root-v2\n' > /etc/liuqin-root-interface
chmod 644 /etc/liuqin-root-interface

# 启用根契约要求的目标单元软链（initramfs 会逐个校验 readlink 目标）
mkdir -p /etc/systemd/system/{basic.target.requires,multi-user.target.wants,graphical.target.wants}
ln -sfn ../liuqin-gnome-storage-guard.service /etc/systemd/system/basic.target.requires/liuqin-gnome-storage-guard.service
ln -sfn ../liuqin-gnome-usb-rescue.service /etc/systemd/system/multi-user.target.wants/liuqin-gnome-usb-rescue.service
ln -sfn ../liuqin-backlight-default.service /etc/systemd/system/graphical.target.wants/liuqin-backlight-default.service
# 不要让 snap admission 挡住 basic.target（liuqin 根契约明确拒绝它）
rm -f /etc/systemd/system/basic.target.requires/liuqin-snap-root-admission.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4) fstab：liuqin 的 PARTLABEL 布局（与 boot.img 的 cmdline/initramfs 对应）
#    root 在 PARTLABEL=linux_root（单系统回退 userdata），LABEL=LIUQIN_ROOT 是权威；
#    可选独立 /home 在 LABEL=LIUQIN_HOME（nofail）。
# ---------------------------------------------------------------------------
log "写 /etc/fstab: PARTLABEL=$PARTLABEL"
cat > /etc/fstab <<EOF
PARTLABEL=$PARTLABEL /     ext4  defaults,x-systemd.growfs  0 1
LABEL=LIUQIN_HOME    /home ext4  defaults,noatime,nofail,x-systemd.growfs  0 2
EOF

# ---------------------------------------------------------------------------
# 5) 基本系统配置
# ---------------------------------------------------------------------------
printf '%s\n' "${HOSTNAME_OVERRIDE:-xiaomi-liuqin}" > /etc/hostname
grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null || echo "127.0.1.1 ${HOSTNAME_OVERRIDE:-xiaomi-liuqin}" >> /etc/hosts
mkdir -p /var/lib /var/log /var/cache/pacman/pkg /run

# ---------------------------------------------------------------------------
# 6) 屏蔽 Valve 分区挂载单元 + partset + adbd gadget + repart/v4l2loopback/fpga
#    （这些单元指向 Steam Frame 的 esp/efi-A/rootfs-A/var-A/home/shared 分区，
#      liuqin 的 GPT 里不存在，会以 no limit 卡住启动。逻辑照抄 steamos-sheng 5.9~5.97。）
# ---------------------------------------------------------------------------
log "屏蔽 Valve 分区挂载单元与 GPT 自动挂载生成器"
ln -sfn /dev/null /etc/systemd/system/systemd-gpt-auto-generator.service 2>/dev/null || true
rm -f /etc/systemd/system/*/systemd-gpt-auto-generator.service 2>/dev/null || true
for _u in home.mount var.mount esp.mount efi.mount efi-A.mount rootfs-A.mount \
          var-A.mount boot-efi.mount; do
  ln -sfn /dev/null "/etc/systemd/system/$_u" 2>/dev/null || true
done
# partset / adbd gadget（Valve 私有 udev 规则，liuqin 无接口，会 no limit 卡住）
for _u in $(ls /etc/systemd/system 2>/dev/null | grep -iE 'adbd|usb-gadget|android-debug' || true); do
  ln -sfn /dev/null "/etc/systemd/system/$_u" 2>/dev/null || true
done
# Deckard 专有：repart 会按 Valve 分区表改磁盘（危险，必须屏蔽）
ln -sfn /dev/null /etc/systemd/system/systemd-repart.service 2>/dev/null || true
rm -f /etc/systemd/system/*/systemd-repart.service 2>/dev/null || true
for _u in v4l2loopback.service fpga-configuration.service fpga-config.service; do
  ln -sfn /dev/null "/etc/systemd/system/$_u" 2>/dev/null || true
done
mkdir -p /etc/repart.d && rm -f /etc/repart.d/* 2>/dev/null || true

# D-Bus messagebus 用户/组（缺失会让 dbus-broker 瞬间退出 → SDDM/图形栈起不来）
getent group messagebus >/dev/null 2>&1 || groupadd -r messagebus 2>/dev/null || true
getent passwd messagebus >/dev/null 2>&1 || useradd -r -g messagebus -d /var/lib/dbus messagebus 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7) 网络与桌面会话（沿用 sheng 结论：SDDM 直连 Plasma，不用 gamescope/VR）
# ---------------------------------------------------------------------------
command -v sddm >/dev/null 2>&1 || pacman -S --noconfirm --needed sddm 2>&1 | tail -3 | sed 's/^/    /' || warn "补装 sddm 失败（保持 Frame 原生会话）"
command -v sddm >/dev/null 2>&1 && systemctl enable sddm.service 2>/dev/null || true

# 登录用户 steamos 的家目录（Frame 的 /home 子卷是空的，被屏蔽挂载后 /home 在根分区）
id steamos >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel,video,audio,steamos steamos 2>/dev/null || true

# Plasma 直连会话（gamescope 的 openvr 后端在平板 LCD 上出 VR 黑帧）
install -d /usr/share/wayland-sessions /etc/sddm.conf.d
cat > /usr/share/wayland-sessions/plasma-liuqin.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Plasma (Wayland, liuqin)
Comment=Start Plasma Wayland directly (no gamescope; the Frame gamescope session targets a VR headset)
Exec=/usr/lib/steamos/liuqin-startplasma
EOF
if [ -x /usr/bin/startplasma-wayland ] || [ -x /usr/lib/steamos/startplasma-wayland ]; then
  cat > /etc/sddm.conf.d/zz-liuqin.conf <<EOF
[Autologin]
User=steamos
Session=plasma-liuqin.desktop
EOF
  log "已创建 Plasma 直连会话，并让 SDDM 自动登录（这是出桌面的关键）"
else
  warn "没有 startplasma-wayland，保持底包默认会话（很可能是 gamescope/VR，平板上会黑）"
fi

# gamescope（游戏模式）后端改 drm，不往 VR 输出
if [ -f /usr/lib/steamos/gamescope-session ]; then
  sed -i 's/--backend openvr/--backend drm/' /usr/lib/steamos/gamescope-session 2>/dev/null \
    && log "gamescope 后端已从 openvr 改为 drm（平板屏）" || true
fi

# ---------------------------------------------------------------------------
# 8) SteamOS-on-ARM 通用修复（照抄 steamos-sheng 11.x / 12.x 的关键项）
# ---------------------------------------------------------------------------
# VARIANT_ID=vr → steamdeck（Frame 的 steamclient 读 VARIANT_ID=vr 会抛 Gamepad UI 异常）
for _osr in /etc/os-release /usr/lib/os-release /var/lib/overlays/etc/upper/os-release; do
  [ -f "$_osr" ] || continue
  grep -q '^VARIANT_ID=' "$_osr" 2>/dev/null || continue
  sed -i 's/^VARIANT_ID=.*/VARIANT_ID="steamdeck"/' "$_osr"
done
log "VARIANT_ID 已改为 steamdeck"

# 无线后端钉回 wpa_supplicant（Steam/steamos-manager 会改 iwd，导致掉线）
install -d /etc/NetworkManager/conf.d /usr/lib/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf <<'EOF'
[connection]
wifi.powersave=2
[device]
wifi.backend=wpa_supplicant
EOF
cp -f /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf /usr/lib/NetworkManager/conf.d/40-liuqin-wifi.conf 2>/dev/null || true
ln -sfn /dev/null /etc/systemd/system/iwd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/iwd.service 2>/dev/null || true

# steamvr 桩（SM8475 无 VR，steam-health-check 调 steamvr 直接成功退出）
install -d /usr/lib/steamos/liuqin-bin
printf '#!/bin/bash\nexit 0\n' > /usr/lib/steamos/liuqin-bin/steamvr
chmod 0755 /usr/lib/steamos/liuqin-bin/steamvr

# 权限位修复（rsync 铺底包会丢 setuid）
cat > /usr/lib/steamos/liuqin-restore-privs <<'EOF'
#!/bin/bash
set -uo pipefail
fix() { [ -e "$1" ] || return 0; chown "$3" "$1" 2>/dev/null || true; chmod "$2" "$1" 2>/dev/null || true; }
fix /usr/bin/pkexec 4755 root:root
fix /usr/bin/sudo 4755 root:root
fix /usr/lib/polkit-1/polkit-agent-helper-1 4755 root:root
fix /usr/bin/su 4755 root:root
fix /usr/bin/passwd 4755 root:root
fix /usr/bin/mount 4755 root:root
fix /usr/bin/umount 4755 root:root
if getent group dbus >/dev/null 2>&1; then fix /usr/lib/dbus-1.0/dbus-daemon-launch-helper 4750 root:dbus
else fix /usr/lib/dbus-1.0/dbus-daemon-launch-helper 4750 root:root; fi
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-restore-privs
bash /usr/lib/steamos/liuqin-restore-privs 2>/dev/null || true

# steam-health-check / steamos-update 替换（Frame 的会抹掉 ARM 客户端 / 走 RAUC）
if [ -e /usr/share/deckard/steam-health-check ]; then
  cp -f /usr/share/deckard/steam-health-check /usr/share/deckard/steam-health-check.stock 2>/dev/null || true
  cat > /usr/share/deckard/steam-health-check <<'EOF'
#!/bin/bash
# liuqin: 不做官方 Frame 的重新解包/抹除；只维护安装完成标记。
set +e
STEAMROOT="${HOME}/.local/share/Steam"
mkdir -p "$STEAMROOT" 2>/dev/null || true
case "${1:-}" in
  --track-started|--track-stopped|--repair-now) touch "$STEAMROOT/.install-complete" 2>/dev/null; rm -f "$STEAMROOT/.crash" 2>/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod 0755 /usr/share/deckard/steam-health-check
fi

# ---------------------------------------------------------------------------
# 9) 无人值守配置：WiFi 凭据 / root 密码 / sshd（设备侧零输入，沿用 sheng）
# ---------------------------------------------------------------------------
if [ -n "${WIFI_SSID:-}" ]; then
  install -d /etc/NetworkManager/system-connections
  NM_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo liuqin-wifi-uuid)"
  cat > "/etc/NetworkManager/system-connections/liuqin-wifi.nmconnection" <<EOF
[connection]
id=${WIFI_SSID}
uuid=${NM_UUID}
type=wifi
autoconnect=true
[wifi]
ssid=${WIFI_SSID}
mode=infrastructure
EOF
  if [ -n "${WIFI_PSK:-}" ]; then
    cat >> "/etc/NetworkManager/system-connections/liuqin-wifi.nmconnection" <<EOF
[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PSK}
EOF
  fi
  chmod 600 "/etc/NetworkManager/system-connections/liuqin-wifi.nmconnection"
  log "已配置 WiFi: ${WIFI_SSID}"
fi

if [ -n "${ROOT_PW:-}" ]; then
  echo "root:${ROOT_PW}" | chpasswd 2>/dev/null || warn "设置 root 密码失败"
fi
if [ -n "${SSH_PUBKEY:-}" ]; then
  install -d -m 700 /root/.ssh
  echo "${SSH_PUBKEY}" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  systemctl enable sshd.service 2>/dev/null || true
  log "已写入 root authorized_keys 并启用 sshd"
fi

# ---------------------------------------------------------------------------
# 10) 自检：关键文件/服务（刷完黑屏的根源排查，缺一个就告警）
# ---------------------------------------------------------------------------
log "自检 liuqin 设备层关键路径"
_missing=0
for _f in /usr/lib/systemd/systemd /usr/bin/hexagonrpcd /usr/libexec/iio-sensor-proxy \
          /usr/local/sbin/liuqin-gnome-storage-guard /usr/local/sbin/liuqin-gnome-usb-rescue \
          /usr/local/sbin/liuqin-wlan-mac /usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin \
          "/usr/share/qcom/sm8450/Xiaomi/liuqin/sensors/sns_reg_version" \
          "/usr/lib/modules/$KREL/modules.dep" /etc/liuqin-native-root \
          /etc/liuqin-root-interface "/usr/share/liuqin/kernels/$KREL/boot.contract" \
          "/usr/share/liuqin/kernels/$KREL/modules.manifest"; do
  if [ -e "$_f" ]; then log "  ✓ $_f"; else warn "  ✗ 缺 $_f"; _missing=$((_missing+1)); fi
done
[ "$_missing" -eq 0 ] || warn "有 $_missing 个关键文件缺失（回看上面的拷贝/契约步骤）"

log "graft 完成：SteamOS userspace + liuqin 内核/固件/设备层 + root contract v2"
exit 0
