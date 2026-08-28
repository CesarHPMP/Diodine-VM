#!/bin/sh
# Enumerate the guest's entire visible attack surface, and try to read back
# through the output channel. Everything is reported as key=value so the host
# harness can assert on it without parsing prose.
set -u
OUT=/diodine/out/probe.txt
port=$(for d in /sys/class/virtio-ports/*; do
           [ "$(cat "$d/name" 2>/dev/null)" = "org.diodine.out" ] && echo "/dev/$(basename "$d")"
       done)

{
  echo "netifs=$(ls /sys/class/net 2>/dev/null | tr '\n' ',')"
  echo "block=$(ls /sys/block 2>/dev/null | tr '\n' ',')"
  echo "usb=$(ls /sys/bus/usb/devices 2>/dev/null | tr '\n' ',')"
  echo "drm=$(ls /sys/class/drm 2>/dev/null | tr '\n' ',')"
  echo "hwrng=$(cat /sys/class/misc/hw_random/rng_current 2>/dev/null || echo none)"
  echo "pci_count=$(ls /sys/bus/pci/devices 2>/dev/null | wc -l)"
  echo "pci=$(for d in /sys/bus/pci/devices/*; do cat "$d/uevent" 2>/dev/null | sed -n 's/^PCI_ID=//p'; done | tr '\n' ',')"

  # FS-001: shared-folder transports must not even be available as filesystem
  # types, let alone mounted.
  echo "has_9p=$(grep -qw 9p /proc/filesystems && echo yes || echo no)"
  echo "has_virtiofs=$(grep -qw virtiofs /proc/filesystems && echo yes || echo no)"
  echo "mounted_9p=$(awk '$3=="9p"||$3=="virtiofs"{print $2}' /proc/mounts | tr '\n' ',')"
  echo "block_mounts=$(awk '$1 ~ /^\/dev\//{print $1}' /proc/mounts | tr '\n' ',')"

  # DEV-004: a clipboard/agent channel would show up as another virtio port.
  echo "virtio_ports=$(for d in /sys/class/virtio-ports/*; do cat "$d/name" 2>/dev/null; done | tr '\n' ',')"

  # OUT-001: try to READ from the output port. Nothing writes to the inbound
  # FIFO on the host, so this must yield zero bytes.
  if [ -n "$port" ]; then
      timeout 3 dd if="$port" of=/tmp/readback bs=1 count=32 2>/dev/null
      echo "readback_bytes=$(wc -c < /tmp/readback 2>/dev/null || echo 0)"
  else
      echo "readback_bytes=noport"
  fi
} > "$OUT" 2>&1
