#!/bin/bash
# QEMU ESP32-S3 Firmware Test Runner (ADR-061)
#
# Builds the firmware with mock CSI enabled, merges binaries into a single
# flash image, optionally injects a pre-provisioned NVS partition, runs the
# image under QEMU with a timeout, and validates the UART output.
#
# Environment variables:
#   QEMU_PATH       - Path to qemu-system-xtensa (default: qemu-system-xtensa)
#   QEMU_TIMEOUT    - Timeout in seconds (default: 60)
#   SKIP_BUILD      - Set to "1" to skip the idf.py build step
#   NVS_BIN         - Path to a pre-built NVS binary to inject (optional)
#
# Exit codes:
#   0  All checks passed
#   1  Warnings (non-critical checks failed)
#   2  Errors (critical checks failed)
#   3  Fatal (crash detected or build failure)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FIRMWARE_DIR="$PROJECT_ROOT/firmware/esp32-csi-node"
BUILD_DIR="$FIRMWARE_DIR/build"
QEMU_BIN="${QEMU_PATH:-qemu-system-xtensa}"
FLASH_IMAGE="$BUILD_DIR/qemu_flash.bin"
LOG_FILE="$BUILD_DIR/qemu_output.log"
TIMEOUT_SEC="${QEMU_TIMEOUT:-60}"

echo "=== QEMU ESP32-S3 Firmware Test (ADR-061) ==="
echo "Firmware dir: $FIRMWARE_DIR"
echo "QEMU binary:  $QEMU_BIN"
echo "Timeout:      ${TIMEOUT_SEC}s"
echo ""

# Verify QEMU is available
if ! command -v "$QEMU_BIN" &>/dev/null; then
    echo "ERROR: QEMU binary not found: $QEMU_BIN"
    echo "Set QEMU_PATH to the qemu-system-xtensa binary."
    exit 3
fi

# 1. Build with mock CSI enabled (skip if already built)
if [ "${SKIP_BUILD:-}" != "1" ]; then
    echo "[1/4] Building firmware (mock CSI mode)..."
    idf.py -C "$FIRMWARE_DIR" \
        -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.qemu" \
        build
    echo ""
else
    echo "[1/4] Skipping build (SKIP_BUILD=1)"
    echo ""
fi

# Verify build artifacts exist
for artifact in \
    "$BUILD_DIR/bootloader/bootloader.bin" \
    "$BUILD_DIR/partition_table/partition-table.bin" \
    "$BUILD_DIR/esp32-csi-node.bin"; do
    if [ ! -f "$artifact" ]; then
        echo "ERROR: Build artifact not found: $artifact"
        echo "Run without SKIP_BUILD=1 or build the firmware first."
        exit 3
    fi
done

# 2. Merge binaries into single flash image
echo "[2/4] Creating merged flash image..."

# Check for ota_data_initial.bin; some builds don't produce it
OTA_DATA_ARGS=""
if [ -f "$BUILD_DIR/ota_data_initial.bin" ]; then
    OTA_DATA_ARGS="0xf000 $BUILD_DIR/ota_data_initial.bin"
fi

python3 -m esptool --chip esp32s3 merge_bin -o "$FLASH_IMAGE" \
    --flash_mode dio --flash_freq 80m --flash_size 8MB \
    0x0     "$BUILD_DIR/bootloader/bootloader.bin" \
    0x8000  "$BUILD_DIR/partition_table/partition-table.bin" \
    $OTA_DATA_ARGS \
    0x20000 "$BUILD_DIR/esp32-csi-node.bin"

echo "Flash image: $FLASH_IMAGE ($(stat -c%s "$FLASH_IMAGE" 2>/dev/null || stat -f%z "$FLASH_IMAGE") bytes)"

# 2b. Optionally inject pre-provisioned NVS partition
NVS_FILE="${NVS_BIN:-$BUILD_DIR/nvs_test.bin}"
if [ -f "$NVS_FILE" ]; then
    echo "[2b] Injecting NVS partition from: $NVS_FILE"
    # NVS partition offset = 0x9000 = 36864
    dd if="$NVS_FILE" of="$FLASH_IMAGE" \
        bs=1 seek=$((0x9000)) conv=notrunc 2>/dev/null
    echo "NVS injected ($(stat -c%s "$NVS_FILE" 2>/dev/null || stat -f%z "$NVS_FILE") bytes at 0x9000)"
fi
echo ""

# 3. Run in QEMU with timeout, capture UART output
echo "[3/4] Running QEMU (timeout: ${TIMEOUT_SEC}s)..."
echo "------- QEMU UART output -------"

# Use timeout command; fall back to gtimeout on macOS
TIMEOUT_CMD="timeout"
if ! command -v timeout &>/dev/null; then
    if command -v gtimeout &>/dev/null; then
        TIMEOUT_CMD="gtimeout"
    else
        echo "WARNING: 'timeout' command not found. QEMU may run indefinitely."
        TIMEOUT_CMD=""
    fi
fi

QEMU_EXIT=0

# Common QEMU arguments
QEMU_ARGS=(
    -machine esp32s3
    -nographic
    -drive "file=$FLASH_IMAGE,if=mtd,format=raw"
    -serial mon:stdio
    -no-reboot
)

# Enable SLIRP user-mode networking for UDP if available
if [ "${QEMU_NET:-1}" != "0" ]; then
    QEMU_ARGS+=(-nic "user,model=open_eth,net=10.0.2.0/24,host=10.0.2.2")
fi

if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD "$TIMEOUT_SEC" "$QEMU_BIN" "${QEMU_ARGS[@]}" \
        2>&1 | tee "$LOG_FILE" || QEMU_EXIT=$?
else
    "$QEMU_BIN" "${QEMU_ARGS[@]}" \
        2>&1 | tee "$LOG_FILE" || QEMU_EXIT=$?
fi

echo "------- End QEMU output -------"
echo ""

# timeout returns 124 when the process is killed by timeout — that's expected
if [ "$QEMU_EXIT" -eq 124 ]; then
    echo "QEMU exited via timeout (expected for firmware that loops forever)."
elif [ "$QEMU_EXIT" -ne 0 ]; then
    echo "WARNING: QEMU exited with code $QEMU_EXIT"
fi
echo ""

# 4. Validate expected output
echo "[4/4] Validating output..."
python3 "$SCRIPT_DIR/validate_qemu_output.py" "$LOG_FILE"
VALIDATE_EXIT=$?

echo ""
echo "=== Test Complete (exit code: $VALIDATE_EXIT) ==="
exit $VALIDATE_EXIT
