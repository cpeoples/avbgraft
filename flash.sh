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
# With --skip-wizard, after the device boots it waits for adb and clears the
# Setup Wizard over adb (settings put ... + force-stop). This only works hands
# off if adb is pre-authorized, so build the image with --bake-adb-key.
#
# Usage:
#   ./flash.sh --out ./out [--serial <SERIAL>] [--no-wipe] [--skip-wizard]

set -euo pipefail

OUT="./out"
SERIAL=""
WIPE="-w"
SKIP_WIZARD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)         OUT="$2"; shift 2 ;;
    --out=*)       OUT="${1#*=}"; shift ;;
    --serial)      SERIAL="$2"; shift 2 ;;
    --serial=*)    SERIAL="${1#*=}"; shift ;;
    --no-wipe)     WIPE=""; shift ;;
    --skip-wizard) SKIP_WIZARD=1; shift ;;
    -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# The bootloader refuses to overwrite an existing custom key slot, so erase
# first (a no-op if empty).
"${FB[@]}" erase avb_custom_key 2>/dev/null || true
"${FB[@]}" flash avb_custom_key "$OUT/avb_pkmd.bin"

echo "[flash] running fastboot update (handles vbmeta -> fastbootd -> super -> system)"
"${FB[@]}" $WIPE update "$OUT/update.zip"

if [[ "$SKIP_WIZARD" -eq 1 ]]; then
  command -v adb >/dev/null 2>&1 || { echo "[flash] warning: adb not on PATH; cannot skip wizard" >&2; SKIP_WIZARD=0; }
fi

if [[ "$SKIP_WIZARD" -eq 1 ]]; then
  ADB=(adb); [[ -n "$SERIAL" ]] && ADB=(adb -s "$SERIAL")
  echo "[flash] waiting for the device to boot and authorize adb ..."
  state=""
  for _ in $(seq 1 40); do
    state="$("${ADB[@]}" get-state 2>/dev/null || true)"
    [[ "$state" == "device" ]] && break
    sleep 5
  done
  if [[ "$state" != "device" ]]; then
    echo "[flash] warning: adb did not reach 'device' (state: ${state:-none})." >&2
    echo "[flash] if it shows 'unauthorized', build with --bake-adb-key for hands-off skip." >&2
  else
    # Wait for boot to fully complete. Writing the provisioning flags before the
    # framework finishes initializing does not stick: it resets them to 0.
    echo "[flash] adb up; waiting for boot to complete ..."
    for _ in $(seq 1 40); do
      [[ "$("${ADB[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && break
      sleep 3
    done
    sleep 5  # settle after boot_completed before touching settings

    echo "[flash] clearing the Setup Wizard"
    apply_skip() {
      "${ADB[@]}" shell 'settings put global device_provisioned 1; \
        settings put secure user_setup_complete 1; \
        settings put global setup_wizard_has_run 1; \
        am force-stop com.google.android.setupwizard; \
        am force-stop com.google.android.pixel.setupwizard; \
        input keyevent KEYCODE_HOME' >/dev/null 2>&1 || true
    }
    # Apply, then verify it stuck; retry once if the framework reset it.
    apply_skip; sleep 2
    dp="$("${ADB[@]}" shell settings get global device_provisioned 2>/dev/null | tr -d '\r')"
    if [[ "$dp" != "1" ]]; then
      echo "[flash] flags did not stick (device_provisioned=$dp); retrying"
      sleep 4; apply_skip; sleep 2
      dp="$("${ADB[@]}" shell settings get global device_provisioned 2>/dev/null | tr -d '\r')"
    fi
    if [[ "$dp" == "1" ]]; then
      echo "[flash] wizard skipped (device_provisioned=1)"
    else
      echo "[flash] warning: wizard flags still not set (device_provisioned=$dp);" >&2
      echo "[flash] rerun the settings put commands once the device is fully booted." >&2
    fi
  fi
fi

echo "[flash] done. First boot marks the A/B slot successful; if it bootloops,"
echo "[flash] reflash the stock factory image to recover (bootloader stays unlocked)."
