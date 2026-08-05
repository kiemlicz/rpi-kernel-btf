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
make olddefconfig

echo "==> Verifying CONFIG_DEBUG_INFO_BTF survived olddefconfig"
if ! grep -q '^CONFIG_DEBUG_INFO_BTF=y$' .config; then
    echo "ERROR: CONFIG_DEBUG_INFO_BTF is not enabled in .config after olddefconfig." >&2
    echo "This usually means CONFIG_DEBUG_INFO_NONE won the Kconfig 'choice' again -- check for upstream defconfig changes." >&2
    exit 1
fi

echo "==> Building bindeb-pkg (this will take a while)"
make -j"$(nproc)" bindeb-pkg KDEB_PKGVERSION="${KDEB_PKGVERSION}"

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
PARENT_DIR="$(cd "$(dirname "${WORKDIR}")" && pwd)"
mkdir -p "${OUTPUT_DIR}"
RESOLVED_OUTPUT="$(cd "${OUTPUT_DIR}" && pwd)"
if [ "${RESOLVED_OUTPUT}" != "${PARENT_DIR}" ]; then
    cp "${PARENT_DIR}"/*.deb "${RESOLVED_OUTPUT}/"
fi

echo "==> Done. Kernel .deb packages with CONFIG_DEBUG_INFO_BTF are in ${OUTPUT_DIR}"
