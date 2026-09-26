#!/usr/bin/env bash
#
# avbgraft: repack a stock Pixel factory image into a debuggable one.
#
# Flips ro.debuggable=0 to 1 in the system partition so a flashed device boots
# with adbd enabled and no Developer-options toggle, then rebuilds the whole
# dm-verity/AVB chain (hashtree + FEC) signed with your own key. The device
# stays verified-boot enforcing under that key; the bootloader can be re-locked
# with it as the avb_custom_key.
#
# It targets the chained-vbmeta layout used by modern Pixels, where the system
# hashtree descriptor lives in vbmeta_system (signed with a separate key), not
# in the top-level vbmeta. avbgraft grafts your key into that chain.
#
# Requirements: Docker (the avbgraft image carries avbroot + debugfs). Build it
# once with: docker build -t avbgraft .
#
# Usage:
#   ./avbgraft.sh --factory <bluejay-*-factory-*.zip> --out ./out [--key key.pem]
#                 [--insecure-adb] [--bake-adb-key[=<adbkey.pub>]]
#
# --insecure-adb also sets ro.adb.secure=0 in /system/build.prop. On some builds
# ro.adb.secure is sourced from the boot ramdisk and this has no effect, so
# prefer --bake-adb-key for promptless adb.
#
# --bake-adb-key writes an adb public key into product at
# /product/etc/security/adb_keys (the target of the /adb_keys symlink), labeled
# u:object_r:adb_keys_file:s0, so the device pre-authorizes that host with no
# prompt even while ro.adb.secure=1. With no value it uses ~/.android/adbkey.pub,
# generating one with `adb keygen` if it does not exist. This also patches and
# re-signs product.img and updates the product digest in vbmeta_system.
#
# Output (in --out): system.img, vbmeta_system.img, vbmeta.img, and the public
# key as avb_pkmd.bin. Flash them with flash.sh, or by hand:
#   fastboot flash avb_custom_key out/avb_pkmd.bin
#   fastboot flash system         out/system.img
#   fastboot flash vbmeta_system  out/vbmeta_system.img
#   fastboot flash vbmeta         out/vbmeta.img
#
# Nothing is flashed by this script. It only produces artifacts.

set -euo pipefail

IMAGE="${AVBGRAFT_IMAGE:-avbgraft}"
FACTORY=""
OUT="./out"
KEY=""
KEEP_WORK=0
INSECURE_ADB=0
BAKE_ADB_KEY=0
ADB_KEY_PATH=""

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --factory)   FACTORY="$2"; shift 2 ;;
    --factory=*) FACTORY="${1#*=}"; shift ;;
    --out)       OUT="$2"; shift 2 ;;
    --out=*)     OUT="${1#*=}"; shift ;;
    --key)       KEY="$2"; shift 2 ;;
    --key=*)     KEY="${1#*=}"; shift ;;
    --keep-work) KEEP_WORK=1; shift ;;
    --insecure-adb) INSECURE_ADB=1; shift ;;
    --bake-adb-key)    BAKE_ADB_KEY=1; shift ;;
    --bake-adb-key=*)  BAKE_ADB_KEY=1; ADB_KEY_PATH="${1#*=}"; shift ;;
    -h|--help)   usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$FACTORY" ]] || { echo "error: --factory <zip> is required" >&2; usage 1; }
[[ -f "$FACTORY" ]] || { echo "error: factory zip not found: $FACTORY" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "error: docker not on PATH" >&2; exit 1; }

# Resolve absolute paths so the container bind-mount is unambiguous.
FACTORY="$(cd "$(dirname "$FACTORY")" && pwd)/$(basename "$FACTORY")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/avbgraft.XXXXXX")"
trap '[[ "$KEEP_WORK" -eq 1 ]] || rm -rf "$WORK"' EXIT

echo "[avbgraft] factory : $FACTORY"
echo "[avbgraft] out     : $OUT"
echo "[avbgraft] work    : $WORK"

# Extract the inner image zip (holds system.img, vbmeta*.img, product.img, ...).
echo "[avbgraft] extracting factory package ..."
unzip -o "$FACTORY" -d "$WORK/factory" >/dev/null
INNER="$(find "$WORK/factory" -name 'image-*.zip' | head -1)"
[[ -n "$INNER" ]] || { echo "error: inner image-*.zip not found in factory zip" >&2; exit 1; }
unzip -o "$INNER" -d "$WORK/img" \
  system.img vbmeta.img vbmeta_system.img product.img system_ext.img pvmfw.img \
  boot.img vbmeta_vendor.img >/dev/null
echo "[avbgraft] extracted system/vbmeta/vbmeta_system (+ product/system_ext/pvmfw/boot/vbmeta_vendor)"

# Copy or generate the signing key into the work dir (bind-mounted into Docker).
if [[ -n "$KEY" ]]; then
  cp "$KEY" "$WORK/key.pem"
  echo "[avbgraft] using provided key: $KEY"
else
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$WORK/key.pem" 2>/dev/null
  echo "[avbgraft] generated a new RSA4096 signing key"
fi

# Resolve the adb public key to bake in, if requested.
#   1. --bake-adb-key=<path>       -> use that file
#   2. --bake-adb-key (no value)   -> ~/.android/adbkey.pub
#   3. if that is missing          -> `adb keygen ~/.android/adbkey` then use it
if [[ "$BAKE_ADB_KEY" -eq 1 ]]; then
  if [[ -z "$ADB_KEY_PATH" ]]; then
    ADB_KEY_PATH="$HOME/.android/adbkey.pub"
    if [[ ! -f "$ADB_KEY_PATH" ]]; then
      if command -v adb >/dev/null 2>&1; then
        echo "[avbgraft] no adb key at $ADB_KEY_PATH; generating one with 'adb keygen'"
        mkdir -p "$HOME/.android"
        adb keygen "$HOME/.android/adbkey" >/dev/null 2>&1 || true
      fi
    fi
  fi
  [[ -f "$ADB_KEY_PATH" ]] || {
    echo "error: --bake-adb-key needs an adb public key, but none was found at" >&2
    echo "       $ADB_KEY_PATH and 'adb keygen' did not produce one." >&2
    echo "       Install platform-tools, or pass --bake-adb-key=<adbkey.pub>." >&2
    exit 1
  }
  cp "$ADB_KEY_PATH" "$WORK/adbkey.pub"
  echo "[avbgraft] baking adb key: $ADB_KEY_PATH"
fi

# Everything below runs inside the container against the bind-mounted work dir.
docker run --rm --platform linux/arm64 \
  -e INSECURE_ADB="$INSECURE_ADB" -e BAKE_ADB_KEY="$BAKE_ADB_KEY" \
  -v "$WORK:/work" "$IMAGE" bash -euo pipefail -c '
  cd /work
  echo "[c] extracting our public key (avb_pkmd)"
  avbroot key extract-avb -k key.pem -o key_pub.bin

  echo "[c] unpacking stock system.img -> avb.toml + raw ext4"
  avbroot avb unpack --input img/system.img
  # avb unpack writes avb.toml + raw.img in the cwd
  STOCK_SYS_DIGEST="$(grep -m1 "root_digest" avb.toml | sed "s/.*= *//; s/[\" ]//g")"

  echo "[c] patching /system/build.prop (system-as-root ext4)"
  debugfs -R "dump /system/build.prop /tmp/bp" raw.img 2>/dev/null
  # ro.debuggable=1 -> adbd starts at boot with no Developer-options toggle.
  sed "s/^ro.debuggable=0\$/ro.debuggable=1/" /tmp/bp > /tmp/bp.new
  # Optional: ro.adb.secure=0 -> adbd skips RSA host authorization (no prompt).
  # This disables adb key auth entirely; only for disposable lab/test devices.
  if [ "${INSECURE_ADB:-0}" = "1" ]; then
    sed -i "s/^ro.adb.secure=1\$/ro.adb.secure=0/" /tmp/bp.new
    echo "[c] insecure-adb: ro.adb.secure=1 -> 0 (adb connects with no RSA prompt)"
  fi
  if ! cmp -s /tmp/bp /tmp/bp.new; then
    printf "rm /system/build.prop\nwrite /tmp/bp.new /system/build.prop\n" | debugfs -w raw.img 2>/dev/null
  else
    echo "[c] warning: no property lines matched; build.prop unchanged" >&2
  fi
  debugfs -R "cat /system/build.prop" raw.img 2>/dev/null | grep -iE "^ro.debuggable|^ro.adb.secure" || true

  echo "[c] repacking system.img with recomputed hashtree + FEC, signed with our key"
  avbroot avb pack --output out_system.img --input-info avb.toml --input-raw raw.img --key key.pem
  NEW_SYS_DIGEST="$(avbroot avb info --input out_system.img 2>/dev/null | grep -m1 root_digest | sed "s/.*: *//; s/[\", ]//g")"
  echo "[c] system root_digest: $STOCK_SYS_DIGEST -> $NEW_SYS_DIGEST"

  # Optionally bake the host adb key into product at /etc/security/adb_keys
  # (product-relative; runtime /product/etc/security/adb_keys). The /adb_keys
  # symlink points here, so adbd pre-authorizes that host with no prompt. The
  # file must be labeled u:object_r:adb_keys_file:s0 or SELinux denies it.
  BAKE_PRODUCT=0
  STOCK_PROD_DIGEST=""
  NEW_PROD_DIGEST=""
  if [ "${BAKE_ADB_KEY:-0}" = "1" ]; then
    echo "[c] baking adb key into product /etc/security/adb_keys"
    avbroot avb unpack --input img/product.img
    mv avb.toml product.toml
    mv raw.img product_raw.img
    STOCK_PROD_DIGEST="$(grep -m1 "root_digest" product.toml | sed "s/.*= *//; s/[\" ]//g")"
    # /etc/security exists on stock product; create the key file inside it.
    printf "cd /etc/security\nwrite /work/adbkey.pub adb_keys\n" | debugfs -w product_raw.img 2>/dev/null
    printf "ea_set /etc/security/adb_keys security.selinux u:object_r:adb_keys_file:s0\\000\n" | debugfs -w product_raw.img 2>/dev/null
    echo "[c] product adb_keys context: $(debugfs -R "ea_list /etc/security/adb_keys" product_raw.img 2>/dev/null | grep selinux | tr -d " ")"
    avbroot avb pack --output out_product.img --input-info product.toml --input-raw product_raw.img --key key.pem
    NEW_PROD_DIGEST="$(avbroot avb info --input out_product.img 2>/dev/null | grep -m1 root_digest | sed "s/.*: *//; s/[\", ]//g")"
    echo "[c] product root_digest: $STOCK_PROD_DIGEST -> $NEW_PROD_DIGEST"
    BAKE_PRODUCT=1
  fi

  echo "[c] rebuilding vbmeta_system (all descriptors) with our new digests"
  avbroot avb unpack --input img/vbmeta_system.img
  mv avb.toml vbmeta_system.toml
  sed "s/${STOCK_SYS_DIGEST}/${NEW_SYS_DIGEST}/" vbmeta_system.toml > vbmeta_system_custom.toml
  if [ "$BAKE_PRODUCT" = "1" ]; then
    sed -i "s/${STOCK_PROD_DIGEST}/${NEW_PROD_DIGEST}/" vbmeta_system_custom.toml
    echo "[c] swapped product digest into vbmeta_system as well"
  fi
  avbroot avb pack --output out_vbmeta_system.img --input-info vbmeta_system_custom.toml --key key.pem

  echo "[c] rebuilding top-level vbmeta: graft our key into the vbmeta_system chain"
  avbroot avb unpack --input img/vbmeta.img
  mv avb.toml vbmeta_top.toml
  # The vbmeta_system chain public_key is the second distinct key in the file;
  # replace whatever key currently signs vbmeta_system with ours. We locate it by
  # reading the stock vbmeta_system public key and swapping that exact blob.
  STOCK_SYS_KEY="$(avbroot avb info --input img/vbmeta_system.img 2>/dev/null | grep -m1 -A1 "Public key" >/dev/null 2>&1; true)"
  OUR_KEY_HEX="$(python3 -c "print(open(\"key_pub.bin\",\"rb\").read().hex())")"
  # Pull the chained vbmeta_system key straight out of the top toml by context.
  CHAIN_KEY="$(python3 - <<PY
import re
t=open("vbmeta_top.toml").read()
# find the chain descriptor block for vbmeta_system and its public_key hex
m=re.search(r"partition_name\s*=\s*\"vbmeta_system\"", t)
# public_key precedes partition_name within the same [[descriptor]] block
blocks=t.split("[[")
key=""
for b in blocks:
    if "vbmeta_system" in b and "public_key" in b:
        km=re.search(r"public_key\s*=\s*\"([0-9a-fA-F]+)\"", b)
        if km: key=km.group(1)
print(key)
PY
)"
  if [[ -n "$CHAIN_KEY" ]]; then
    sed "s/${CHAIN_KEY}/${OUR_KEY_HEX}/" vbmeta_top.toml > vbmeta_top_custom.toml
    echo "[c] grafted our key into the vbmeta_system chain descriptor"
  else
    echo "[c] error: could not locate vbmeta_system chain key in top vbmeta" >&2
    exit 1
  fi
  avbroot avb pack --output out_vbmeta.img --input-info vbmeta_top_custom.toml --key key.pem

  echo "[c] verifying the re-signed chain against our key"
  # avbroot verifies the top vbmeta recursively: chained images (boot,
  # vbmeta_system, vbmeta_vendor) plus any hash/hashtree partition present is
  # checked. Missing images are ignored by default, so we stage the chained
  # images and the partitions we re-signed; the untouched bootloader partitions
  # (dtbo, abl, ...) are skipped. This checks our system hashtree + FEC, the
  # vbmeta_system signature, and the top-level vbmeta signature in one pass.
  mkdir -p verify && cd verify
  cp ../out_vbmeta.img        vbmeta.img
  cp ../out_vbmeta_system.img vbmeta_system.img
  cp ../out_system.img        system.img
  if [ -f ../out_product.img ]; then cp ../out_product.img product.img; else cp ../img/product.img product.img; fi
  cp ../img/system_ext.img    system_ext.img
  cp ../img/pvmfw.img         pvmfw.img
  cp ../img/boot.img          boot.img
  cp ../img/vbmeta_vendor.img vbmeta_vendor.img
  avbroot avb verify --input vbmeta.img --public-key ../key_pub.bin
  cd ..
'

# Collect artifacts.
cp "$WORK/out_system.img"        "$OUT/system.img"
cp "$WORK/out_vbmeta_system.img" "$OUT/vbmeta_system.img"
cp "$WORK/out_vbmeta.img"        "$OUT/vbmeta.img"
cp "$WORK/key_pub.bin"           "$OUT/avb_pkmd.bin"
cp "$WORK/key.pem"               "$OUT/signing_key.pem"
[[ -f "$WORK/out_product.img" ]] && cp "$WORK/out_product.img" "$OUT/product.img"

# Build a modified update zip: a copy of the stock inner image-*.zip with our
# re-signed images swapped in. `fastboot update` reads this zip and runs the
# vendor fastboot-info.txt sequence, which flashes vbmeta first, reboots into
# fastbootd on its own, resizes super, then flashes the logical system (and
# product) partitions. This is the reliable way to flash a re-signed system: it
# avoids flashing logical partitions from the regular bootloader (which fails)
# and avoids manually wrangling fastbootd.
if command -v zip >/dev/null 2>&1; then
  echo "[avbgraft] building update zip (stock image zip + our re-signed images) ..."
  UPDATE_DIR="$WORK/update"
  mkdir -p "$UPDATE_DIR"
  cp "$INNER" "$UPDATE_DIR/image.zip"
  # Overwrite only the images we re-signed; everything else stays stock.
  cp "$WORK/out_system.img"        "$UPDATE_DIR/system.img"
  cp "$WORK/out_vbmeta.img"        "$UPDATE_DIR/vbmeta.img"
  cp "$WORK/out_vbmeta_system.img" "$UPDATE_DIR/vbmeta_system.img"
  ZIP_FILES=(system.img vbmeta.img vbmeta_system.img)
  if [[ -f "$WORK/out_product.img" ]]; then
    cp "$WORK/out_product.img" "$UPDATE_DIR/product.img"
    ZIP_FILES+=(product.img)
  fi
  ( cd "$UPDATE_DIR" && zip -q image.zip "${ZIP_FILES[@]}" )
  cp "$UPDATE_DIR/image.zip" "$OUT/update.zip"
else
  echo "[avbgraft] warning: 'zip' not found on host; skipping update.zip build" >&2
  echo "[avbgraft] install zip, or flash the individual images (see README)" >&2
fi

echo
echo "[avbgraft] done. Artifacts in $OUT:"
ls -la "$OUT" | awk 'NR>1 {print "  " $5 "  " $9}'
echo
echo "[avbgraft] keep signing_key.pem safe; you need it to re-sign future builds"
echo "[avbgraft] flash with: ./flash.sh --out $OUT   (or see README)"
