#!/usr/bin/env bash
# Apply the RK3588 four-bank IOMMU integration, or verify it is already applied.
set -euo pipefail
LINUX_DIR="$(cd "${1:?usage: apply-kernel-patches.sh <linux-dir>}" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH="$SCRIPT_DIR/../linux-integration/rk3588-npu-iommu.patch"
cd "$LINUX_DIR"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "RK3588 NPU IOMMU patch already applied"
else
  echo "NPU IOMMU patch does not match this kernel; review before building" >&2
  exit 1
fi
