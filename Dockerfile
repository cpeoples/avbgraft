# Container image for avbgraft.
#
# Provides a native aarch64 toolchain for repacking and re-signing AVB
# (Android Verified Boot) images:
#   - avbroot   : unpack/pack/verify AVB, hashtree + FEC generation (Rust, no
#                 external `fec` binary needed)
#   - debugfs   : edit files inside an ext4 partition image without mounting
#   - android-sdk-libsparse-utils : simg2img / img2simg for sparse images
#
# Built for linux/arm64 so avbroot's aarch64 release runs natively on Apple
# Silicon under Docker.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip e2fsprogs android-sdk-libsparse-utils python3 \
    && rm -rf /var/lib/apt/lists/*

# Pin avbroot to a known-good release. Override with --build-arg AVBROOT_VERSION=...
ARG AVBROOT_VERSION=3.34.1
RUN url="https://github.com/chenxiaolong/avbroot/releases/download/v${AVBROOT_VERSION}/avbroot-${AVBROOT_VERSION}-aarch64-linux-android31.zip" \
    && curl -fsSL "$url" -o /tmp/avbroot.zip \
    && unzip -o /tmp/avbroot.zip -d /usr/local/bin avbroot \
    && chmod +x /usr/local/bin/avbroot \
    && rm /tmp/avbroot.zip

WORKDIR /work
