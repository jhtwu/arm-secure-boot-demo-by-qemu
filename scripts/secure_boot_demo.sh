#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
SRC_DIR="$ROOT_DIR/third_party"
BUILD_DIR="$ROOT_DIR/build"
OUT_DIR="$ROOT_DIR/out"
LOG_DIR="$ROOT_DIR/logs"
PAYLOAD_DIR="$ROOT_DIR/payload"
UBOOT_SRC="$SRC_DIR/u-boot"
TFA_SRC="$SRC_DIR/tf-a"
MBEDTLS_SRC="$SRC_DIR/mbedtls"
UBOOT_BUILD="$BUILD_DIR/u-boot"
FIT_BUILD="$BUILD_DIR/fit"
FIT_KEYS_DIR="$BUILD_DIR/fit-keys"
FIT_IMAGE="$OUT_DIR/secure_fit.itb"
FLASH_IMAGE="$OUT_DIR/flash.bin"
LOG_FILE="$LOG_DIR/secure_boot.log"
UBOOT_DTB="$UBOOT_BUILD/arch/arm/dts/qemu-arm64.dtb"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH=arm
NPROC=$(nproc)

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[!] Missing required command: $1" >&2
        exit 1
    fi
}

prepare_dirs() {
    mkdir -p "$BUILD_DIR" "$OUT_DIR" "$LOG_DIR" "$FIT_BUILD" "$FIT_KEYS_DIR"
}

check_prereqs() {
    for cmd in openssl ${CROSS_COMPILE}gcc qemu-system-aarch64 python3 timeout script col; do
        require_cmd "$cmd"
    done
}

build_uboot() {
    echo "[+] Building U-Boot (secure configuration)"
    rm -rf "$UBOOT_BUILD"
    mkdir -p "$UBOOT_BUILD"
    pushd "$UBOOT_SRC" >/dev/null
    ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE make O="$UBOOT_BUILD" distclean >/dev/null
    ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE make O="$UBOOT_BUILD" qemu_arm64_defconfig >/dev/null
    ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
        KCONFIG_CONFIG="$UBOOT_BUILD/.config" \
        bash ./scripts/kconfig/merge_config.sh -O "$UBOOT_BUILD" \
        configs/qemu_arm64_defconfig "$ROOT_DIR/config/u-boot/secure_boot.config" >/dev/null
    ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE make O="$UBOOT_BUILD" olddefconfig >/dev/null
    ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE make O="$UBOOT_BUILD" -j"$NPROC"
    popd >/dev/null
}

generate_fit_keys() {
    echo "[+] Generating signing/encryption material"
    rm -rf "$FIT_KEYS_DIR"
    mkdir -p "$FIT_KEYS_DIR"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$FIT_KEYS_DIR/dev.key" >/dev/null 2>&1
    openssl req -batch -new -x509 -key "$FIT_KEYS_DIR/dev.key" -out "$FIT_KEYS_DIR/dev.crt" \
        -subj "/CN=SecureBootDemo/" >/dev/null 2>&1
    # AES-256 key for FIT payload encryption
    openssl rand -out "$FIT_KEYS_DIR/enc.bin" 32
}

prepare_fit_image() {
    echo "[+] Preparing signed && encrypted FIT payload"
    rm -rf "$FIT_BUILD"
    mkdir -p "$FIT_BUILD"
    cp "$PAYLOAD_DIR/fit.its" "$FIT_BUILD/fit.its"
    cp "$PAYLOAD_DIR/payload.bin" "$FIT_BUILD/payload.bin"
    pushd "$FIT_BUILD" >/dev/null
    "$UBOOT_BUILD/tools/mkimage" -f fit.its -k "$FIT_KEYS_DIR" \
        -K "$UBOOT_DTB" -r secure_fit.itb
    popd >/dev/null
    # Re-pack U-Boot binary with updated DTB that now contains key/cipher nodes
    cat "$UBOOT_BUILD/u-boot-nodtb.bin" "$UBOOT_DTB" > "$UBOOT_BUILD/u-boot.bin"
    cp "$UBOOT_BUILD/u-boot.bin" "$OUT_DIR/u-boot.bin"
    cp "$UBOOT_DTB" "$OUT_DIR/u-boot.dtb"
    cp "$FIT_BUILD/secure_fit.itb" "$FIT_IMAGE"
}

build_tf_a() {
    echo "[+] Building Trusted Firmware-A with Trusted Board Boot"
    pushd "$TFA_SRC" >/dev/null
    make -C "$TFA_SRC" distclean >/dev/null || true
    make CROSS_COMPILE=$CROSS_COMPILE PLAT=qemu DEBUG=1 LOG_LEVEL=50 \
        MBEDTLS_DIR="$MBEDTLS_SRC" TRUSTED_BOARD_BOOT=1 GENERATE_COT=1 \
        SAVE_KEYS=1 BL33="$OUT_DIR/u-boot.bin" all fip -j"$NPROC"
    popd >/dev/null
    local tfa_out="$TFA_SRC/build/qemu/debug"
    mkdir -p "$OUT_DIR"
    dd if="$tfa_out/bl1.bin" of="$FLASH_IMAGE" bs=4096 conv=notrunc status=none
    dd if="$tfa_out/fip.bin" of="$FLASH_IMAGE" seek=64 bs=4096 conv=notrunc status=none
    cp "$tfa_out/fip.bin" "$OUT_DIR/fip.bin"
}

run_qemu() {
    echo "[+] Launching QEMU to exercise secure boot chain"
    rm -f "$LOG_FILE"
    local tmp_raw tmp_clean
    tmp_raw=$(mktemp "$LOG_DIR/secure_boot.XXXXXX.raw")
    tmp_clean=$(mktemp "$LOG_DIR/secure_boot.XXXXXX.log")
    local qemu_cmd=(qemu-system-aarch64 -machine virt,secure=on -cpu cortex-a57 \
        -smp 2 -m 1024 -nographic -monitor none -serial mon:stdio \
        -device loader,file="$FIT_IMAGE",addr=0x40200000 -bios "$FLASH_IMAGE")
    printf '    %s ' "${qemu_cmd[@]}"; echo
    set +e
    script -q -f "$tmp_raw" -c "timeout --preserve-status 20s ${qemu_cmd[*]}"
    local qemu_status=$?
    set -e
    if [[ -s "$tmp_raw" ]]; then
        col -b <"$tmp_raw" | sed '1{/^Script started on /d};$ {/^Script done on /d}' >"$tmp_clean"
        mv "$tmp_clean" "$LOG_FILE"
    else
        : >"$LOG_FILE"
    fi
    rm -f "$tmp_raw" "$tmp_clean" 2>/dev/null || true
    chmod 664 "$LOG_FILE"
    return $qemu_status
}

main() {
    check_prereqs
    prepare_dirs
    build_uboot
    generate_fit_keys
    prepare_fit_image
    build_tf_a
    run_qemu
    echo "[+] Log written to $LOG_FILE"
}

main "$@"
