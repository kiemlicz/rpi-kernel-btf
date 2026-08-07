#!/usr/bin/env bash
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/raspberrypi/linux.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-rpi-6.18.y}"
DEFCONFIG="${DEFCONFIG:-bcm2712_defconfig}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
KDEB_PKGVERSION="${KDEB_PKGVERSION:-1.0-custom-btf}"
WORKDIR="${WORKDIR:-$(pwd)/build}"
mkdir -p "$(dirname "${WORKDIR}")"
WORKDIR="$(cd "$(dirname "${WORKDIR}")" && pwd)/$(basename "${WORKDIR}")"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

export ARCH CROSS_COMPILE
# scripts/setlocalversion appends "+" whenever LOCALVERSION is merely
# *unset* and the tree isn't at a clean signed tag -- true for any
# --depth=1 clone regardless of CONFIG_LOCALVERSION_AUTO. Setting it
# (even empty) short-circuits that check.
export LOCALVERSION=

echo "==> Cloning ${KERNEL_REPO} (branch ${KERNEL_BRANCH}) into ${WORKDIR}"
rm -rf "${WORKDIR}"
git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${WORKDIR}"
cd "${WORKDIR}"

echo "==> Applying ${DEFCONFIG}"
make "${DEFCONFIG}"

echo "==> Enabling CONFIG_DEBUG_INFO_BTF and its prerequisites"
# CONFIG_DEBUG_INFO_NONE is the default of a Kconfig 'choice' in RPi
# defconfigs. Enabling CONFIG_DEBUG_INFO_BTF alone is not enough: unless
# DEBUG_INFO_NONE is explicitly disabled, `make olddefconfig` re-resolves
# the choice back to DEBUG_INFO_NONE=y and silently drops
# CONFIG_DEBUG_INFO_BTF again.
./scripts/config --disable CONFIG_DEBUG_INFO_NONE
./scripts/config --enable  CONFIG_DEBUG_INFO_DWARF5
./scripts/config --enable  CONFIG_DEBUG_INFO_BTF
./scripts/config --enable  CONFIG_BPF_SYSCALL

# raspi-firmware's postinst hook derives the boot image slot via
# ${kernel_version#*-rpi-} and matches it with an exact `case` pattern
# (e.g. "2712"), so no extra suffix can survive. CONFIG_LOCALVERSION_AUTO
# appends a "+" when git describe can't find a clean tag -- guaranteed
# with our --depth=1 clone -- so it must be disabled here.
./scripts/config --disable CONFIG_LOCALVERSION_AUTO
./scripts/config --set-str CONFIG_LOCALVERSION "+rpt-rpi-2712"

make olddefconfig

echo "==> Verifying CONFIG_DEBUG_INFO_BTF survived olddefconfig"
if ! grep -q '^CONFIG_DEBUG_INFO_BTF=y$' .config; then
    echo "ERROR: CONFIG_DEBUG_INFO_BTF is not enabled in .config after olddefconfig." >&2
    echo "This usually means CONFIG_DEBUG_INFO_NONE won the Kconfig 'choice' again -- check for upstream defconfig changes." >&2
    exit 1
fi

echo "==> Building bindeb-pkg (this will take a while)"
make -j"$(nproc)" bindeb-pkg KDEB_PKGVERSION="${KDEB_PKGVERSION}"

echo "==> Patching missing overlays/README into linux-image .deb"
# arch/arm/boot/dts/overlays/README exists in-tree but isn't part of the
# dtbs_install file list, so vanilla bindeb-pkg drops it. raspi-firmware's
# postinst hook rsyncs it as a required (non-glob) source and hard-fails
# with exit 23 if it's missing, so it has to be injected after packaging.
KERNEL_RELEASE="$(cat include/config/kernel.release)"
PARENT_DIR="$(cd "$(dirname "${WORKDIR}")" && pwd)"
IMAGE_DEB="${PARENT_DIR}/linux-image-${KERNEL_RELEASE}_${KDEB_PKGVERSION}_arm64.deb"
if [ -f "${IMAGE_DEB}" ] && [ -f "arch/arm/boot/dts/overlays/README" ]; then
    PATCH_DIR="$(mktemp -d)"
    dpkg-deb -R "${IMAGE_DEB}" "${PATCH_DIR}"
    mkdir -p "${PATCH_DIR}/usr/lib/linux-image-${KERNEL_RELEASE}/overlays"
    cp arch/arm/boot/dts/overlays/README "${PATCH_DIR}/usr/lib/linux-image-${KERNEL_RELEASE}/overlays/README"
    ( cd "${PATCH_DIR}" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | xargs -0 md5sum > DEBIAN/md5sums )
    dpkg-deb -b "${PATCH_DIR}" "${IMAGE_DEB}"
    rm -rf "${PATCH_DIR}"
else
    echo "WARNING: expected ${IMAGE_DEB} or source README not found, skipping README patch" >&2
fi

echo "==> Verifying built vmlinux contains a BTF section"
VMLINUX="${WORKDIR}/vmlinux"
if [ ! -f "${VMLINUX}" ]; then
    echo "ERROR: vmlinux not found at ${VMLINUX}" >&2
    exit 1
fi
if ! readelf -S "${VMLINUX}" | grep -q '\.BTF '; then
    echo "ERROR: built vmlinux does not contain a .BTF section -- BTF was not actually generated." >&2
    exit 1
fi
echo "==> BTF section confirmed present in vmlinux"

echo "==> Collecting *.deb packages into ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
RESOLVED_OUTPUT="$(cd "${OUTPUT_DIR}" && pwd)"
if [ "${RESOLVED_OUTPUT}" != "${PARENT_DIR}" ]; then
    cp "${PARENT_DIR}"/*.deb "${RESOLVED_OUTPUT}/"
fi

echo "==> Done. Kernel .deb packages with CONFIG_DEBUG_INFO_BTF are in ${OUTPUT_DIR}"
