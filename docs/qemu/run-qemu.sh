#!/usr/bin/env bash
# Tesla Linux — qemu raspi4b (preferred) / virt fallback.
# SERIAL=stdio (default) for interactive getty login; SERIAL=sock for logfile-only.
set -euo pipefail
ROOT="${TESLA_LINUX_QEMU_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
IMG="${IMG:-$ROOT/tesla-linux-20260902-pi.img}"
KERNEL="${KERNEL:-$ROOT/boot/vmlinux}"
DTB="${DTB:-$ROOT/boot/bcm2711-rpi-4-b.dtb}"
INITRD="${INITRD:-$ROOT/boot/initrd.img}"
INITRD_VIRT="${INITRD_VIRT:-$ROOT/boot/initrd-virt.img}"
MODE="${1:-raspi4b}"
TAP="${TAP:-tesla0}"
SERIAL="${SERIAL:-stdio}"
mkdir -p "$ROOT/shots" "$ROOT/boot" "$ROOT/evidence"

serial_args=()
case "$SERIAL" in
  stdio)
    serial_args=(
      -chardev "stdio,id=serial0,logfile=$ROOT/serial.log,signal=off"
      -serial chardev:serial0
    )
    ;;
  sock|socket)
    serial_args=(
      -chardev "socket,id=serial0,path=$ROOT/serial.sock,server=on,wait=off,logfile=$ROOT/serial.log,signal=off"
      -serial chardev:serial0
    )
    ;;
  *)
    echo "SERIAL=$SERIAL (use stdio or sock)" >&2
    exit 2
    ;;
esac

ensure_sd_power2() {
  local sz; sz=$(stat -c %s "$IMG")
  if [ "$sz" -lt $((16*1024*1024*1024)) ]; then
    qemu-img resize -f raw "$IMG" 16G
  fi
}
setup_tap() {
  if ! ip link show "$TAP" >/dev/null 2>&1; then
    sudo ip tuntap add "$TAP" mode tap user "$(id -un)"
  fi
  sudo ip addr flush dev "$TAP" || true
  sudo ip addr add 10.42.0.254/24 dev "$TAP" || true
  sudo ip addr add 10.42.1.2/24 dev "$TAP" || true
  sudo ip link set "$TAP" up
}
run_raspi4b() {
  ensure_sd_power2
  setup_tap
  echo "Starting raspi4b SERIAL=$SERIAL (2GiB smp4 TCG usb-net=$TAP VNC:1 serial=stdio)"
  echo "Serial login: teslalinux / teslalinux (factory). Type on this stdio."
  exec qemu-system-aarch64 \
    -M raspi4b -cpu cortex-a72 -smp 4 -m 2048 -accel tcg,thread=multi \
    -kernel "$KERNEL" -dtb "$DTB" -initrd "$INITRD" \
    -append "rw earlycon=pl011,0xfe201000 console=serial0,115200 console=ttyAMA0,115200 console=tty1 random.trust_cpu=on root=LABEL=writable rootfstype=ext4 panic=10 rootwait fsck.repair=yes" \
    -drive "file=$IMG,if=sd,format=raw" \
    "${serial_args[@]}" \
    -monitor "unix:$ROOT/monitor.sock,server=on,wait=off" \
    -display vnc=127.0.0.1:1 \
    -device usb-kbd -device usb-tablet \
    -netdev "tap,id=n0,ifname=$TAP,script=no,downscript=no" \
    -device usb-net,netdev=n0 \
    -D "$ROOT/qemu.log"
}
run_virt() {
  setup_tap
  local initrd="$INITRD"; [ -f "$INITRD_VIRT" ] && initrd="$INITRD_VIRT"
  echo "Starting virt SERIAL=$SERIAL initrd=$(basename "$initrd") serial=stdio"
  echo "Serial login: teslalinux / teslalinux (factory). Type on this stdio."
  exec qemu-system-aarch64 \
    -M virt -cpu max -smp 4 -m 4096 -accel tcg,thread=multi \
    -kernel "$KERNEL" -initrd "$initrd" \
    -append "rw console=serial0,115200 console=ttyAMA0,115200 console=tty1 earlycon=pl011,0x09000000 random.trust_cpu=on root=LABEL=writable rootfstype=ext4 panic=10 rootwait" \
    -drive "if=none,id=hd0,file=$IMG,format=raw" -device virtio-blk-pci,drive=hd0 \
    -netdev "tap,id=n0,ifname=$TAP,script=no,downscript=no" -device virtio-net-pci,netdev=n0 \
    -device virtio-gpu-pci -device ramfb \
    "${serial_args[@]}" \
    -monitor "unix:$ROOT/monitor.sock,server=on,wait=off" \
    -display vnc=127.0.0.1:1 -D "$ROOT/qemu.log"
}
case "$MODE" in raspi4b) run_raspi4b;; virt) run_virt;; *) echo "usage: $0 [raspi4b|virt]" >&2; exit 2;; esac
