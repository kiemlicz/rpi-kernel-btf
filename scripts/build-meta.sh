#!/usr/bin/env bash
set -euo pipefail

# Builds linux-image-rpi-<flavour> and linux-headers-rpi-<flavour> metapackages depending on an
# already published custom kernel, without building the kernel itself.
# archive.raspberrypi.com ships same-named metapackages that track the stock kernel. Publishing ours
# lets hosts pin them to this repo, so `apt upgrade` follows custom builds instead of pulling the stock kernel.
# The epoch (stock uses 1:) keeps these ahead of the stock ones even where the pin is missing.

KERNEL_RELEASE="${KERNEL_RELEASE:?KERNEL_RELEASE must be set, e.g. 6.18.42+rpt-rpi-2712}"
KDEB_PKGVERSION="${KDEB_PKGVERSION:-1.0-custom-btf}"
ARCH="${ARCH:-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
mkdir -p "${OUTPUT_DIR}"

KERNEL_VERSION="${KERNEL_RELEASE%%+*}"
FLAVOUR="${KERNEL_RELEASE#*-rpi-}"
META_VERSION="${META_VERSION:-2:${KERNEL_VERSION}+${KDEB_PKGVERSION}}"

build_meta() {
    local name="$1" depends="$2" provides="$3"
    local meta_dir
    meta_dir="$(mktemp -d)"
    # mktemp creates 0700; the package root must not ship that mode for "/"
    chmod 0755 "${meta_dir}"
    mkdir -p "${meta_dir}/DEBIAN"
    cat > "${meta_dir}/DEBIAN/control" <<EOF
Package: ${name}
Version: ${META_VERSION}
Architecture: ${ARCH}
Maintainer: l3a <noreply@l3a.dev>
Section: kernel
Priority: optional
Depends: ${depends}
${provides:+Provides: ${provides}
}Description: Linux with BTF for Raspberry Pi ${FLAVOUR} (meta-package)
 Depends on the latest custom BTF-enabled kernel build (${KERNEL_RELEASE}).
EOF
    # dpkg-deb names files without the epoch, matching how bindeb-pkg names its .debs
    dpkg-deb --root-owner-group -b "${meta_dir}" "${OUTPUT_DIR}/${name}_${META_VERSION#*:}_${ARCH}.deb"
    rm -rf "${meta_dir}"
}

echo "==> Building linux-image/linux-headers metapackages ${META_VERSION} for ${KERNEL_RELEASE}"
build_meta "linux-image-rpi-${FLAVOUR}" \
    "linux-image-${KERNEL_RELEASE} (= ${KDEB_PKGVERSION})" \
    "linux-latest-modules-${KERNEL_RELEASE}, wireguard-modules (= 1.0.0)"
build_meta "linux-headers-rpi-${FLAVOUR}" \
    "linux-headers-${KERNEL_RELEASE} (= ${KDEB_PKGVERSION})" \
    ""
