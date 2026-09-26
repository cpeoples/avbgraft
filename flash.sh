#!/usr/bin/env bash
#
# flash.sh: flash an avbgraft artifact set to a connected, bootloader-unlocked
# Pixel and register the custom AVB key.
#
# This is destructive to the flashed partitions. The device must already be
# unlocked (fastboot flashing unlock). Run avbgraft.sh first to produce --out.
#
# Usage:
#   ./flash.sh --out ./out [--serial <SERIAL>]

set -euo pipefail

OUT="./out"
SERIAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)      OUT="$2"; shift 2 ;;
    --out=*)    OUT="${1#*=}"; shift ;;
    --serial)   SERIAL="$2"; shift 2 ;;
    --serial=*) SERIAL="${1#*=}"; shift ;;
    -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v fastboot >/dev/null 2>&1 || { echo "error: fastboot not on PATH" >&2; exit 1; }
for f in system.img vbmeta_system.img vbmeta.img avb_pkmd.bin; do
  [[ -f "$OUT/$f" ]] || { echo "error: missing $OUT/$f (run avbgraft.sh first)" >&2; exit 1; }
done

FB=(fastboot)
[[ -n "$SERIAL" ]] && FB=(fastboot -s "$SERIAL")

echo "[flash] devices in fastboot:"; "${FB[@]}" devices
echo "[flash] this ERASES the flashed partitions on the unlocked device. Ctrl-C to abort."
sleep 3

echo "[flash] registering custom AVB key"
"${FB[@]}" flash avb_custom_key "$OUT/avb_pkmd.bin"

echo "[flash] flashing system + vbmeta_system + vbmeta"
"${FB[@]}" flash system        "$OUT/system.img"
"${FB[@]}" flash vbmeta_system "$OUT/vbmeta_system.img"
"${FB[@]}" flash vbmeta        "$OUT/vbmeta.img"

echo "[flash] rebooting"
"${FB[@]}" reboot
echo "[flash] done. First boot marks the A/B slot successful; if it bootloops,"
echo "[flash] reflash the stock factory image to recover (bootloader stays unlocked)."
