#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
OUT_DIR="$ROOT_DIR/out"
LOG_DIR="$ROOT_DIR/logs"
FLASH_IMAGE="$OUT_DIR/flash.bin"
FIT_IMAGE="$OUT_DIR/secure_fit.itb"
LOG_FILE="$LOG_DIR/secure_boot_run.log"
QEMU_TIMEOUT="20s"
LOG_ENABLED=1

usage() {
    cat <<'EOF'
Usage: run_secure_boot_only.sh [--timeout <value>] [--no-log]

  --timeout <value>  Override QEMU runtime limit (passed to coreutils timeout).
  --no-log           Stream output only; skip writing logs/secure_boot_run.log.

Requires prior build via scripts/secure_boot_demo.sh.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            [[ $# -lt 2 ]] && { echo "[!] --timeout requires a value" >&2; exit 1; }
            QEMU_TIMEOUT="$2"
            shift 2
            ;;
        --no-log)
            LOG_ENABLED=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[!] Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[!] Missing required command: $1" >&2
        exit 1
    fi
}

require_file() {
    if [[ ! -s "$1" ]]; then
        echo "[!] Required file '$1' is missing or empty. Run scripts/secure_boot_demo.sh first." >&2
        exit 1
    fi
}

run_qemu() {
    mkdir -p "$LOG_DIR"

    local qemu_cmd=(qemu-system-aarch64 -machine virt,secure=on -cpu cortex-a57 \
        -smp 2 -m 1024 -nographic -monitor none -serial mon:stdio \
        -device loader,file="$FIT_IMAGE",addr=0x40200000 -bios "$FLASH_IMAGE")

    echo "[+] Launching QEMU"
    printf '    %s ' "${qemu_cmd[@]}"; echo

    local qemu_status
    if [[ $LOG_ENABLED -eq 1 ]]; then
        local tmp_raw tmp_clean
        tmp_raw=$(mktemp "$LOG_DIR/secure_boot_run.XXXXXX.raw")
        tmp_clean=$(mktemp "$LOG_DIR/secure_boot_run.XXXXXX.log")
        set +e
        script -q -f "$tmp_raw" -c "timeout --preserve-status $QEMU_TIMEOUT ${qemu_cmd[*]}"
        qemu_status=$?
        set -e
        if [[ -s "$tmp_raw" ]]; then
            col -b <"$tmp_raw" | sed '1{/^Script started on /d};$ {/^Script done on /d}' >"$tmp_clean"
            mv "$tmp_clean" "$LOG_FILE"
        else
            : >"$LOG_FILE"
        fi
        rm -f "$tmp_raw" "$tmp_clean" 2>/dev/null || true
        chmod 664 "$LOG_FILE"
        local size
        size=$(wc -c <"$LOG_FILE")
        echo "[+] Log captured at $LOG_FILE (${size} bytes)"
    else
        set +e
        timeout --preserve-status "$QEMU_TIMEOUT" "${qemu_cmd[@]}"
        qemu_status=$?
        set -e
        echo "[+] Logging disabled; console output only"
    fi

    return $qemu_status
}

main() {
    require_cmd qemu-system-aarch64
    require_cmd timeout
    if [[ $LOG_ENABLED -eq 1 ]]; then
        require_cmd script
        require_cmd col
    fi
    require_file "$FLASH_IMAGE"
    require_file "$FIT_IMAGE"
    run_qemu
}

main "$@"
