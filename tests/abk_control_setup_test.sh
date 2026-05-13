#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

KERNEL_ROOT="$TMP_DIR/kernel"
DEFCONFIG="$TMP_DIR/gki_defconfig"
CUSTOM_EXTERNAL_MODULES_MANIFEST="$TMP_DIR/modules.tsv"

mkdir -p "$KERNEL_ROOT/common/drivers" "$KERNEL_ROOT/common/include/linux"
printf 'menu "Device Drivers"\nendmenu\n' > "$KERNEL_ROOT/common/drivers/Kconfig"
printf '# drivers makefile\n' > "$KERNEL_ROOT/common/drivers/Makefile"
printf '# defconfig\n' > "$DEFCONFIG"

make_module() {
  local dir="$1"
  local id="$2"
  local name="$3"
  local version="$4"
  local description="$5"

  mkdir -p "$dir"
  {
    printf 'ABK_MODULE_ID="%s"\n' "$id"
    printf 'ABK_MODULE_NAME="%s"\n' "$name"
    printf 'ABK_MODULE_VERSION="%s"\n' "$version"
    printf 'ABK_MODULE_DESCRIPTION="%s"\n' "$description"
  } > "$dir/module.conf"
}

make_module "$TMP_DIR/mod_alpha" "alpha_feature" "Alpha Feature" "1.0" "alpha metadata"
make_module "$TMP_DIR/mod_beta" "beta_feature" "Beta Feature" "2.0" "beta \"quoted\" metadata"

{
  printf 'after_patch\t%s\t%s\n' "$REPO_ROOT" "https://github.com/xingguangcuican6666/ABK_control_module"
  printf 'before_build\t%s\t%s\n' "$REPO_ROOT" "https://github.com/xingguangcuican6666/ABK_control_module"
  printf 'after_patch\t%s\t%s\n' "$TMP_DIR/mod_alpha" "https://example.invalid/alpha.git"
  printf 'before_build\t%s\t%s\n' "$TMP_DIR/mod_beta" "https://example.invalid/beta.git"
} > "$CUSTOM_EXTERNAL_MODULES_MANIFEST"

export KERNEL_ROOT DEFCONFIG CUSTOM_EXTERNAL_MODULES_MANIFEST
export CONFIG="android15-6.6-test"
export ABK_BUILD_ANDROID_VERSION="android15"
export ABK_BUILD_KERNEL_VERSION="6.6"
export ABK_BUILD_SUB_LEVEL="test"
export ABK_BUILD_OS_PATCH_LEVEL="2025-01"
export ABK_BUILD_REVISION="r1"
export ABK_BUILD_KSU_VARIANT="SukiSU"
export ABK_BUILD_KSU_BRANCH="Stable(标准)"
export ABK_BUILD_VERSION="ABK-test"
export ABK_BUILD_TIME="Wed May 13 14:00:00 CST 2026"
export ABK_BUILD_VIRTUALIZATION_SUPPORT="678"
export ABK_BUILD_ZRAM_EXTRA_ALGOS="lz4,zstd"
export ABK_FEATURE_USE_ZRAM="true"
export ABK_FEATURE_USE_BBG="false"
export ABK_FEATURE_USE_DDK="true"
export ABK_FEATURE_USE_NTSYNC="true"
export ABK_FEATURE_USE_NETWORKING="false"
export ABK_FEATURE_USE_KPM="true"
export ABK_FEATURE_USE_REKERNEL="false"
export ABK_FEATURE_ENABLE_SUSFS="true"
export ABK_FEATURE_SUPP_OP="false"
export ABK_FEATURE_ZRAM_FULL_ALGO="true"

(
  cd "$REPO_ROOT"
  CUSTOM_EXTERNAL_MODULE_STAGE=after_patch bash setup.sh
  CUSTOM_EXTERNAL_MODULE_STAGE=before_build bash setup.sh
  CUSTOM_EXTERNAL_MODULE_STAGE=before_build bash setup.sh
)

assert_file() {
  local path="$1"
  [ -f "$path" ] || {
    printf 'missing file: %s\n' "$path" >&2
    exit 1
  }
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local actual

  actual="$(grep -cF "$pattern" "$file" || true)"
  if [ "$actual" != "$expected" ]; then
    printf 'expected %s occurrences of %s in %s, got %s\n' \
      "$expected" "$pattern" "$file" "$actual" >&2
    exit 1
  fi
}

assert_file "$KERNEL_ROOT/common/drivers/abk_control/core.c"
assert_file "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
assert_file "$KERNEL_ROOT/common/include/linux/abk_control.h"

assert_count 1 'source "drivers/abk_control/Kconfig"' "$KERNEL_ROOT/common/drivers/Kconfig"
assert_count 1 'obj-$(CONFIG_ABK_CONTROL) += abk_control/' "$KERNEL_ROOT/common/drivers/Makefile"
assert_count 1 'CONFIG_ABK_CONTROL=y' "$DEFCONFIG"

grep -qF '.id = "abk_control"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.version = "0.2.0"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.stage = "after_patch,before_build"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.id = "alpha_feature"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.id = "beta_feature"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.description = "beta \"quoted\" metadata"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF 'const size_t abk_control_manifest_count = 3;' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF 'const struct abk_control_build_info abk_control_build = {' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.android_version = "android15"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.kernel_version = "6.6"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.os_patch_level = "2025-01"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.kernelsu_variant = "SukiSU"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.virtualization_support = "678"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.zram_extra_algos = "lz4,zstd"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.use_zram = true' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.use_bbg = false' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '.enable_susfs = true' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
grep -qF '\"schema\": 3' "$KERNEL_ROOT/common/drivers/abk_control/core.c"
grep -qF 'ABK_JSON_FIELD("source", source);' "$KERNEL_ROOT/common/drivers/abk_control/core.c"

printf 'abk_control_setup_test passed\n'
