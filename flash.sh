#!/usr/bin/env bash
#
# flash.sh: flash an avbgraft artifact set to a connected, bootloader-unlocked
# Pixel and register the custom AVB key.
#
# This is destructive to the flashed partitions and wipes userdata. The device
# must already be unlocked (fastboot flashing unlock). Run avbgraft.sh first to
# produce --out.
#
# It uses `fastboot update out/update.zip`, which follows the vendor
# fastboot-info.txt sequence: flash vbmeta, reboot into fastbootd, resize super,
# then flash the logical system partition. This is the reliable path; flashing the
# logical system partition from the regular bootloader does not work.
#
# Usage:
#   ./flash.sh --out ./out [--serial <SERIAL>] [--no-wipe]

set -euo pipefail

OUT="./out"
SERIAL=""
WIPE="-w"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)      OUT="$2"; shift 2 ;;
    --out=*)    OUT="${1#*=}"; shift ;;
    --serial)   SERIAL="$2"; shift 2 ;;
    --serial=*) SERIAL="${1#*=}"; shift ;;
    --no-wipe)  WIPE=""; shift ;;
    -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v fastboot >/dev/null 2>&1 || { echo "error: fastboot not on PATH" >&2; exit 1; }
[[ -f "$OUT/avb_pkmd.bin" ]] || { echo "error: missing $OUT/avb_pkmd.bin (run avbgraft.sh first)" >&2; exit 1; }
[[ -f "$OUT/update.zip"   ]] || { echo "error: missing $OUT/update.zip (run avbgraft.sh with 'zip' installed)" >&2; exit 1; }

FB=(fastboot)
[[ -n "$SERIAL" ]] && FB=(fastboot -s "$SERIAL")

echo "[flash] devices in fastboot:"; "${FB[@]}" devices
echo "[flash] product: $("${FB[@]}" getvar product 2>&1 | head -1)"
echo "[flash] unlocked: $("${FB[@]}" getvar unlocked 2>&1 | head -1)"
echo "[flash] this ERASES the flashed partitions${WIPE:+ and wipes userdata}. Ctrl-C to abort."
sleep 4

echo "[flash] registering custom AVB key"
"${FB[@]}" flash avb_custom_key "$OUT/avb_pkmd.bin"

echo "[flash] running fastboot update (handles vbmeta -> fastbootd -> super -> system)"
"${FB[@]}" $WIPE update "$OUT/update.zip"

echo "[flash] done. First boot marks the A/B slot successful; if it bootloops,"
echo "[flash] reflash the stock factory image to recover (bootloader stays unlocked)."
