# ARM Secure Boot Demo by QEMU

A self-contained workflow that demonstrates an Arm secure boot chain on QEMU using Trusted Firmware-A (TF-A) and U-Boot. The project builds the firmware stack, prepares a signed and encrypted FIT payload, and exercises the boot flow under QEMU while capturing console logs for analysis.

---

## Overview | 專案概覽

- **Trusted Firmware-A** builds with Trusted Board Boot enabled and verifies BL33 (U-Boot).
- **U-Boot** verifies a signed FIT image and decrypts an AES-encrypted payload.
- **QEMU** emulates the Arm `virt` machine in Secure mode to execute the full boot chain entirely in software.

---

## Prerequisites | 事前準備

Install the following packages on the host system:

- `qemu-system-aarch64`
- `aarch64-linux-gnu-gcc`
- `make`, `git`, `python3`
- `openssl`
- `timeout`, `script`, `col` (usually part of GNU coreutils and util-linux)

在主機系統安裝以下套件：

- `qemu-system-aarch64`
- `aarch64-linux-gnu-gcc`
- `make`、`git`、`python3`
- `openssl`
- `timeout`、`script`、`col`（一般由 GNU coreutils / util-linux 提供）

> The scripts download third-party sources (TF-A, U-Boot, Mbed TLS) on first use. Internet access is required the first time you run the build. 首次執行建置腳本會自動下載第三方原始碼，需有網路連線。

---

## Directory Layout | 目錄結構

- `scripts/secure_boot_demo.sh` – Full build + run pipeline.
- `scripts/run_secure_boot_only.sh` – Rerun QEMU using existing artifacts.
- `config/`, `payload/`, `out/`, `logs/`, `build/` – Supporting configuration, FIT payload, generated binaries, and captured logs.

---

## Initial Build & Run | 首次建置與執行

```bash
./scripts/secure_boot_demo.sh
```

This script:

1. Checks prerequisites and prepares working directories.
2. Clones TF-A, U-Boot, and Mbed TLS if missing.
3. Builds U-Boot with secure boot configuration.
4. Generates signing/encryption material and FIT payload.
5. Builds TF-A with Trusted Board Boot enabled.
6. Launches QEMU (20 s timeout) and captures the console to `logs/secure_boot.log`.

腳本流程：

1. 檢查所需工具並建立目錄。
2. 如未存在，自動下載 TF-A、U-Boot、Mbed TLS 原始碼。
3. 以安全開機設定編譯 U-Boot。
4. 產生簽署與加密所需的金鑰，並建立 FIT 映像。
5. 啟用 Trusted Board Boot 編譯 TF-A。
6. 啟動 QEMU（預設 20 秒後自動結束），將主控台輸出存至 `logs/secure_boot.log`。

> After the run, the key firmware images are located in `out/flash.bin`, `out/secure_fit.itb`, and U-Boot binaries under `out/`. 執行完成後，主要韌體映像位於 `out/` 目錄。

---

## Re-running QEMU Only | 僅重新執行 QEMU

If you already built the images, rerun QEMU without rebuilding:

```bash
./scripts/run_secure_boot_only.sh [--timeout <value>] [--no-log]
```

- `--timeout <value>` – Override the default 20 s timeout (e.g., `--timeout 60s`).
- `--no-log` – Disable log capture and print output only to the console.

The script stores the boot log in `logs/secure_boot_run.log` and prints the file size when logging is enabled.

若已建置完成，可直接重新模擬：

```bash
./scripts/run_secure_boot_only.sh [--timeout <秒數>] [--no-log]
```

- `--timeout <秒數>` – 覆寫預設的 20 秒執行時間上限，例如 `--timeout 60s`。
- `--no-log` – 僅顯示主控台輸出，不寫入 log 檔。

腳本會在啟用日誌時將輸出寫入 `logs/secure_boot_run.log`，並顯示檔案大小以確認內容完整。

---

## Artifacts & Logs | 產出與紀錄

- `out/flash.bin` – Combined BL1 + FIP image used as QEMU `-bios`.
- `out/secure_fit.itb` – Signed & encrypted FIT payload loaded at runtime.
- `logs/secure_boot.log` – Full build-and-run transcript.
- `logs/secure_boot_run.log` – QEMU-only run transcript.

---

## Cleaning Up | 清除產出

Delete the `build/`, `out/`, and `logs/` directories to remove generated artifacts. If you need a pristine workspace, also remove the `third_party/` folder to force re-cloning upstream sources.

刪除 `build/`、`out/`、`logs/` 目錄即可清除產出。若需回到初始狀態，可額外移除 `third_party/` 重新下載原始碼。

---

## Notes | 補充說明

- QEMU runs in non-interactive mode (`-nographic`) and automatically terminates after the configured timeout. If you need to interact manually, run QEMU directly:

  ```bash
  qemu-system-aarch64 -machine virt,secure=on -cpu cortex-a57 -smp 2 -m 1024 \
      -nographic -monitor none -serial mon:stdio \
      -device loader,file=out/secure_fit.itb,addr=0x40200000 -bios out/flash.bin
  ```

- The current demo decrypts an encrypted FIT payload and shows the raw contents via U-Boot memory dump; extend U-Boot handlers if you want to boot a real kernel or execute the payload directly.

- To regenerate keys with fixed values (e.g., for deterministic demos), replace the auto-generated files under `build/fit-keys/` with your own static material before running the scripts.

---

## License | 授權

This repository is provided for demonstration purposes. Third-party components (TF-A, U-Boot, Mbed TLS) retain their own licenses.

本專案僅供示範。TF-A、U-Boot、Mbed TLS 等第三方原始碼各自擁有其授權條款。
