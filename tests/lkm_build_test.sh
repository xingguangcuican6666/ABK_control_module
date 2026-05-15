#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

assert_line() {
  local expected="$1"
  local actual="$2"

  if [ "$expected" != "$actual" ]; then
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_variant() {
  local variant="$1"
  local kmi="$2"
  local expected_dir="$3"
  local expected_artifact="$4"
  local output

  output="$(bash "$REPO_ROOT/lkm/build.sh" --variant "$variant" --kmi "$kmi" --dry-run)"
  assert_line "$(printf '%s\t%s\t%s' "$variant" "$expected_dir" "$expected_artifact")" "$output"
}

assert_variant \
  kernelsu \
  android15-6.6 \
  "$REPO_ROOT/external/KernelSU/kernel" \
  "$REPO_ROOT/lkm/out/kernelsu/android15-6.6_kernelsu.ko"

assert_variant \
  sukisu \
  android15-6.6 \
  "$REPO_ROOT/external/SukiSU-Ultra/kernel" \
  "$REPO_ROOT/lkm/out/sukisu/android15-6.6_kernelsu.ko"

assert_variant \
  resukisu \
  android16-6.12 \
  "$REPO_ROOT/external/ReSukiSU/kernel" \
  "$REPO_ROOT/lkm/out/resukisu/android16-6.12_kernelsu.ko"

custom_out="$(LKM_OUT_DIR="$REPO_ROOT/custom-out" bash "$REPO_ROOT/lkm/build.sh" --variant kernelsu --kmi android14-6.1 --dry-run)"
assert_line \
  "$(printf '%s\t%s\t%s' kernelsu "$REPO_ROOT/external/KernelSU/kernel" "$REPO_ROOT/custom-out/kernelsu/android14-6.1_kernelsu.ko")" \
  "$custom_out"

list_output="$(bash "$REPO_ROOT/lkm/build.sh" --list)"
assert_line $'kernelsu\nsukisu\nresukisu' "$list_output"

printf 'lkm_build_test passed\n'
