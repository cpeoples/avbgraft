# avbgraft

> ⭐ If avbgraft is useful to you, a star on the repo is appreciated.
> Please also star the projects it stands on:
> [avbroot](https://github.com/chenxiaolong/avbroot) and
> [regraph](https://github.com/tmzt/regraph).

Repack a stock Pixel factory image into a **debuggable** one. It flips
`ro.debuggable=0` to `1` in the system partition so a flashed device boots with
`adbd` enabled and no Developer-options toggle, then rebuilds the whole
dm-verity/AVB chain (hashtree plus FEC) signed with **your own key**. The device
stays Verified Boot **enforcing** under that key, and the bootloader can be
re-locked with it as the `avb_custom_key`.

This targets the **chained-vbmeta** layout used by modern Pixels, where the
`system` hashtree descriptor lives in `vbmeta_system` (signed with a separate
key), not in the top-level `vbmeta`. avbgraft grafts your key into that chain.

## Why

On a stock `user` build, enabling USB debugging on a freshly-flashed or
factory-reset device means tapping through the Setup Wizard, revealing Developer
options, and toggling USB debugging by hand. For a lab or test device you flash
repeatedly, that manual process is slow. Setting `ro.debuggable=1` in the
image starts `adbd` at boot with no toggle. Because that edits the
Verified-Boot-protected `system` partition, the dm-verity hashtree and the
`vbmeta` signature have to be recomputed, which is what avbgraft automates.

Scope note: this changes the **provisioning / debuggability** boundary on a
device you own with an unlocked bootloader. It is **not** an FRP or lock-screen
bypass.

## What it does NOT do

- It does **not** enable `adb root`. That needs the `su` SELinux domain, which
  `user` builds omit. That is a separate, larger change.
- It does **not** skip the Setup Wizard. That is a runtime provisioning change
  (a Magisk `service.d` script or `settings put` flags), independent of the
  image.
- It does **not** bake in a pre-authorized adb key. `/adb_keys` on Pixels
  symlinks into the `product` partition, so that would also require patching
  `product.img` and its hashtree (a planned extension).

## Requirements

### On the host

- **Docker** runs the pipeline container. Verified with Docker Desktop on macOS
  (Apple Silicon / arm64); any host that can run `--platform linux/arm64` works.
- **`openssl`** generates the RSA4096 signing key when `--key` is not given (it
  ships with macOS and every mainstream Linux).
- **`unzip`** extracts the factory package (preinstalled on macOS/Linux).
- **`bash`** runs `avbgraft.sh` and `flash.sh`.
- **Android platform-tools** (`fastboot`, and `adb` to reach fastboot) are only
  needed to flash, via `flash.sh`. They are not needed to build artifacts.

### Inside the container (installed by the `Dockerfile`, nothing to do by hand)

- **[`avbroot`](https://github.com/chenxiaolong/avbroot)** (pinned via
  `AVBROOT_VERSION`, default 3.34.1): AVB pack/unpack/verify with native
  dm-verity hashtree **and FEC**, so no external AOSP `fec` binary is required.
- **`e2fsprogs`** provides `debugfs`, used to edit `/system/build.prop` inside
  the ext4 image without mounting it.
- **`android-sdk-libsparse-utils`** provides `simg2img` and `img2simg` for
  sparse images.
- **`python3`** parses the vbmeta TOML to locate the `vbmeta_system` chain key.
- **`ca-certificates`** and **`curl`** fetch the pinned avbroot release at build
  time.

### On the device

- A **bootloader-unlocked** Pixel (`fastboot flashing unlock`), with **OEM
  unlocking** enabled in Developer options first.

## Build the container once

```bash
docker build -t avbgraft .
```

The image is built `linux/arm64` so avbroot's aarch64 release runs natively on
Apple Silicon. Pin a different avbroot with `--build-arg AVBROOT_VERSION=x.y.z`.

## Produce artifacts

```bash
./avbgraft.sh --factory bluejay-<build>-factory-<hash>.zip --out ./out
```

- Reuses an existing signing key with `--key mykey.pem`; otherwise it generates
  a fresh RSA4096 key and writes it to `out/signing_key.pem`.
- Output in `out/`: `system.img`, `vbmeta_system.img`, `vbmeta.img`,
  `avb_pkmd.bin` (your public key, for `avb_custom_key`), and `update.zip` (a
  copy of the stock image zip with the three re-signed images swapped in, for
  `fastboot update`).

The script verifies the full chain against your key before finishing.

### `--insecure-adb` (no RSA prompt) and `--bake-adb-key` (pre-authorized host)

By default the patched image sets `ro.debuggable=1`, which starts `adbd` at
boot. The first host connection still shows the "Allow USB debugging from this
computer?" prompt.

There are two ways to remove that prompt:

- **`--bake-adb-key[=<adbkey.pub>]`** (recommended) writes an adb public key into
  product at `/product/etc/security/adb_keys` (the target of the `/adb_keys`
  symlink), labeled `u:object_r:adb_keys_file:s0` so SELinux allows it. The
  device then pre-authorizes that host with no prompt, even with
  `ro.adb.secure=1`. With no value it uses `~/.android/adbkey.pub`, generating
  one with `adb keygen` if it does not exist. This also patches and re-signs
  `product.img` and updates the product digest in `vbmeta_system`, so `out/` and
  `update.zip` will include `product.img`.

- **`--insecure-adb`** flips `ro.adb.secure=0` in `/system/build.prop`. On this
  Pixel build the effective `ro.adb.secure` is sourced from the boot ramdisk,
  not `/system/build.prop`, so this flag alone does not remove the prompt.
  Prefer `--bake-adb-key`.

```bash
# promptless adb by pre-authorizing your host key (validated end to end):
./avbgraft.sh --factory <zip> --out ./out --bake-adb-key
```

After flashing with `--bake-adb-key`, `adb shell` works immediately with no tap,
even after a userdata wipe, because the authorization lives in `product`, not in
`/data`.

### Skipping the Setup Wizard

avbgraft does not bake a Setup Wizard skip into the image, and it cannot: the
wizard state lives in the `settings` provider on the `/data` partition, which is
wiped on every flash, and the legacy `ro.setupwizard.*` build properties are
ignored on current Pixels. Skip it at runtime over adb instead (this is why
promptless adb via `--bake-adb-key` matters):

```bash
adb shell settings put global device_provisioned 1
adb shell settings put secure  user_setup_complete 1
adb shell settings put global setup_wizard_has_run 1
adb shell am force-stop com.google.android.setupwizard
adb shell am force-stop com.google.android.pixel.setupwizard
```

Modern Pixels run two setup wizard packages (`com.google.android.setupwizard`
and `com.google.android.pixel.setupwizard`); stop both.

## Flash

```bash
./flash.sh --out ./out --serial <SERIAL>
```

`flash.sh` registers the custom key and then runs `fastboot update`, which
follows the vendor `fastboot-info.txt` sequence: it flashes `vbmeta` and
`vbmeta_system`, reboots into fastbootd, resizes `super`, then flashes the
logical `system` partition. This is the sequence Google's own factory
`flash-all` uses.

By hand, in fastboot:

```bash
fastboot flash avb_custom_key out/avb_pkmd.bin
fastboot -w update out/update.zip
```

`system` is a logical partition inside `super`, so it cannot be flashed from the
regular bootloader (`fastboot flash system` fails with
`resize-logical-partition ... Invalid command`). It must be flashed from
fastbootd, which `fastboot update` enters automatically. Use `--no-wipe` on the
script (or drop `-w`) to keep userdata.

## Caveats

- **Rollback index is one-way.** Once the device boots a newer build, AVB bumps
  the rollback index and the older patched slot is refused even while unlocked.
  Re-run avbgraft on each new build's factory zip; you cannot downgrade.
- **Match the build.** The factory zip must match the build you intend to run.
- **Keep your key.** `signing_key.pem` is required to re-sign future builds and
  is the root of trust if you relock. Losing it means reflashing stock.
- **Recovery.** If a flash bootloops, reflash the stock factory image; the
  bootloader stays unlocked.

## Validation

This pipeline was validated end-to-end, fully offline, on a real Pixel 6a
(`bluejay`) factory image before any device was flashed. Nothing was flashed
during validation; it produced artifacts and verified the AVB chain against the
custom key.

- **Image:** `bluejay-cp3a.260905.009` (inner `image-bluejay-cp3a.260905.009.zip`).
- **`system` patch:** `ro.debuggable=0` to `1` in `/system/build.prop` via
  `debugfs` (single byte; ext4 layout unchanged).
- **`system` hashtree recomputed with FEC:** root digest changed from
  `9d8cb02c...` (stock) to `5febee85...` (ours), `fec_num_roots = 2`,
  `fec_size = 8847360`. The output `system.img` was byte-for-byte the same size
  as stock (`1127792640` bytes), confirming the footer, hashtree, and FEC
  geometry matched.
- **`vbmeta_system` rebuilt** with all four descriptors (`system`, `product`,
  `system_ext`, `pvmfw`), swapping only the `system` digest, re-signed with our
  key. Size unchanged (`4096` bytes).
- **Top-level `vbmeta` rebuilt** (`12288` bytes, unchanged), grafting our public
  key into the `vbmeta_system` chain descriptor while leaving `boot` and
  `vbmeta_vendor` chained to the stock Google keys.
- **Full-chain verify passed.** `avbroot avb verify` from the top `vbmeta`, with
  the real `system`, `product` (4 GB), `system_ext`, and `pvmfw` staged, hashed
  each partition against its descriptor (about 34 s) and reported:

  ```
  Verifying hash tree descriptor for: system
  Verifying hash tree descriptor for: product
  Verifying hash tree descriptor for: system_ext
  Verifying hash descriptor for: boot / pvmfw
  Successfully verified all vbmeta signatures and hashes
  ```

The `fec` tool is the missing piece on a plain macOS host: AOSP's `fec` CLI is not
packaged for macOS, Debian, or Alpine and must be built from AOSP source.
Running the pipeline in the Linux container with `avbroot`, which implements FEC
natively in Rust, removed that dependency entirely.

## How it works

1. Extract `system.img` and `vbmeta*.img` (plus `product`, `system_ext`,
   `pvmfw`) from the factory zip's inner `image-*.zip`.
2. `avbroot avb unpack` the stock `system.img` into `avb.toml` and a raw ext4.
3. `debugfs` edits `/system/build.prop` in the raw ext4 (system-as-root),
   flipping `ro.debuggable`. It is a single byte, so the ext4 layout is
   unchanged.
4. `avbroot avb pack` recomputes the `system` dm-verity hashtree plus FEC over
   the patched filesystem and signs the footer with your key.
5. Rebuild `vbmeta_system` from the stock descriptors, swapping in the new
   `system` root digest, signed with your key.
6. Rebuild the top-level `vbmeta`, grafting your public key into the
   `vbmeta_system` chain descriptor while leaving the `boot` and `vbmeta_vendor`
   chains pointing at the stock keys.
7. Verify the whole chain against your key.

## Credits

avbgraft is a thin wrapper around work by others. The parts that matter,
computing the dm-verity hashtree, generating FEC, and re-signing the AVB chain,
are done by these projects:

- **[chenxiaolong/avbroot](https://github.com/chenxiaolong/avbroot)** (GPL-3.0)
  does the core work: AVB pack/unpack/verify with native dm-verity
  hashtree **and FEC** in Rust, which is what makes this work without building
  AOSP's `fec` tool. avbgraft invokes it as a separate binary.
- **[tmzt/regraph](https://github.com/tmzt/regraph)** (Apache-2.0) is the prior
  art and the concept: repacking a stock image with `ro.debuggable=1` and
  re-signing verified boot so `adb root` works, with nothing else changed.
- **[AOSP `external/avb`](https://android.googlesource.com/platform/external/avb/)**
  (Apache-2.0) is the Android Verified Boot 2.0 design and the original
  `avbtool`.
- **`e2fsprogs`** (`debugfs`) and **`android-sdk-libsparse-utils`** provide the
  ext4 and sparse-image tooling, invoked as separate programs.

avbgraft does not bundle or link any of these; the container downloads and runs
them as separate processes, so this project's own code is offered under the MIT
license below.

## License

[MIT](LICENSE), Chris Peoples. The tools it orchestrates keep their own licenses
(see Credits).

## References

- [Android Verified Boot 2.0](https://android.googlesource.com/platform/external/avb/+/master/README.md):
  the AVB design, chained partitions, and `avbtool`.
- [AOSP `init.usb.rc`](https://android.googlesource.com/platform/system/core/+/refs/heads/main/rootdir/init.usb.rc):
  how `ro.debuggable` and `persist.sys.usb.config` start `adbd`.

---

**⭐ If avbgraft saved you time, please star this repo.**

And please also star the projects it stands on, since they do the work that
matters:

- ⭐ [avbroot](https://github.com/chenxiaolong/avbroot)
- ⭐ [regraph](https://github.com/tmzt/regraph)
