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

make_dispatch_fixture() {
  local dir="$1"

  mkdir -p "$dir/supercall"
  cat > "$dir/supercall/dispatch.c" <<'EOF_DISPATCH'
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#include "manager/manager_identity.h"

static int do_get_info(void __user *arg)
{
    struct ksu_get_info_cmd cmd = { .version = KERNEL_SU_VERSION, .flags = 0 };

    if (is_manager()) {
        cmd.flags |= KSU_GET_INFO_FLAG_MANAGER;
    }

    return 0;
}

static int do_grant_root(void __user *arg)
{
    return 0;
}

// IOCTL handlers mapping table
static const struct ksu_ioctl_cmd_map ksu_ioctl_handlers[] = {
    {
        .cmd = KSU_IOCTL_GET_INFO,
        .name = "GET_INFO",
        .handler = do_get_info,
        .perm_check = always_allow
    },
    {
        .cmd = 0,
        .name = NULL,
        .handler = NULL,
        .perm_check = NULL
    },
};

long ksu_supercall_handle_ioctl(unsigned int cmd, void __user *argp)
{
    return 0;
}
EOF_DISPATCH
}

make_single_ksu_fixture() {
  local dir="$1"

  mkdir -p "$dir/manager"
  printf 'kernelsu-objs += manager/apk_sign.o\n' > "$dir/Kbuild"
  cat > "$dir/manager/apk_sign.c" <<'EOF_APK'
bool is_manager_apk(char *path)
{
#ifdef KSU_MANAGER_PACKAGE
    char pkg[KSU_MAX_PACKAGE_NAME];
    if (get_pkg_from_apk_path(pkg, path) < 0) {
        pr_err("Failed to get package name from apk path: %s\n", path);
        return false;
    }

    // pkg is `<real package>`
    if (strncmp(pkg, KSU_MANAGER_PACKAGE, sizeof(KSU_MANAGER_PACKAGE))) {
        return false;
    }
#endif
    if (check_v2_signature(path, EXPECTED_SIZE, EXPECTED_HASH)) {
        return true;
    }
#ifdef EXPECTED_SIZE2
    return check_v2_signature(path, EXPECTED_SIZE2, EXPECTED_HASH2);
#else
    return false;
#endif
}
EOF_APK
  cat > "$dir/manager/throne_tracker.h" <<'EOF_SINGLE_HEADER'
#ifndef __KSU_H_UID_OBSERVER
#define __KSU_H_UID_OBSERVER

#ifdef CONFIG_KSU_DISABLE_MANAGER
static inline void ksu_throne_tracker_init()
{
}
static inline void ksu_throne_tracker_exit()
{
}
static inline void track_throne(bool prune_only)
{
    (void)prune_only;
}
#else
void ksu_throne_tracker_init();
void ksu_throne_tracker_exit();
void track_throne(bool prune_only);
#endif

#endif
EOF_SINGLE_HEADER
  cat > "$dir/manager/throne_tracker.c" <<'EOF_SINGLE_TRACKER'
#define SYSTEM_PACKAGES_LIST_PATH "/data/system/packages.list"

static void crown_manager(const char *apk, struct list_head *uid_data)
{
    char pkg[KSU_MAX_PACKAGE_NAME];
    if (get_pkg_from_apk_path(pkg, apk) < 0) {
        return;
    }

    pr_info("manager pkg: %s\n", pkg);

    ksu_set_manager_appid(10000);
}

void search_manager(void)
{
            if (is_manager) {
                crown_manager(dirpath, my_ctx->private_data);
                *my_ctx->stop = 1;

                // Manager found, clear APK cache list
                list_for_each_entry_safe (pos, n, &apk_path_hash_list, list) {
                    list_del(&pos->list);
                    kfree(pos);
                }
            } else {
            }
}

void track_throne(bool prune_only)
{
}

void __init ksu_throne_tracker_init()
{
}
EOF_SINGLE_TRACKER
  make_dispatch_fixture "$dir"
}

make_resukisu_fixture() {
  local dir="$1"

  mkdir -p "$dir/manager"
  printf 'kernelsu-objs += manager/apk_sign.o\n' > "$dir/Kbuild"
  cat > "$dir/manager/apk_sign.c" <<'EOF_RE_APK'
static apk_sign_key_t apk_sign_keys[] = {
    { EXPECTED_SIZE_RESUKISU, EXPECTED_HASH_RESUKISU },
};

bool is_manager_apk(char *path, u8 *signature_index)
{
#ifdef KSU_MANAGER_PACKAGE
    char pkg[KSU_MAX_PACKAGE_NAME];
    if (get_pkg_from_apk_path(pkg, path) < 0) {
        return false;
    }

    if (strncmp(pkg, KSU_MANAGER_PACKAGE, sizeof(KSU_MANAGER_PACKAGE))) {
        return false;
    }
#endif
    return check_v2_signature(path, signature_index);
}
EOF_RE_APK
  cat > "$dir/manager/throne_tracker.h" <<'EOF_RE_HEADER'
#ifndef __KSU_H_THRONE_TRACKER
#define __KSU_H_THRONE_TRACKER

#define TRACK_THRONE_PRUNE_ONLY (1 << 0)
#define TRACK_THRONE_FORCE_SEARCH_MGR (1 << 1)

#ifdef CONFIG_KSU_DISABLE_MANAGER
static inline void track_throne(unsigned int flags)
{
}
#else
void track_throne(unsigned int flags);
#endif

#endif
EOF_RE_HEADER
  cat > "$dir/manager/throne_tracker.c" <<'EOF_RE_TRACKER'
struct track_throne_struct {
    unsigned int flags;
};

void do_track_throne(void *data)
{
}

void track_throne(unsigned int flags)
{
}
EOF_RE_TRACKER
  make_dispatch_fixture "$dir"
}

make_single_ksu_fixture "$KERNEL_ROOT/KernelSU/kernel"
make_single_ksu_fixture "$KERNEL_ROOT/drivers/kernelsu"
make_resukisu_fixture "$KERNEL_ROOT/common/drivers/kernelsu"

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
grep -qF '.version = "0.5.0"' "$KERNEL_ROOT/common/drivers/abk_control/abk_control_manifest.c"
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
grep -qF 'ABK_JSON_FIELD("type", "builtin");' "$KERNEL_ROOT/common/drivers/abk_control/core.c"
grep -qF 'ABK_JSON_FIELD("source", source);' "$KERNEL_ROOT/common/drivers/abk_control/core.c"
grep -qF '\"readonly\": %s' "$KERNEL_ROOT/common/drivers/abk_control/core.c"
grep -qF 'abk_control_get_status_json' "$KERNEL_ROOT/common/include/linux/abk_control.h"
grep -qF 'abk_control_run_command' "$KERNEL_ROOT/common/include/linux/abk_control.h"
grep -qF 'ABK_CONTROL_IOCTL_GET_STATUS' "$KERNEL_ROOT/common/include/linux/abk_control.h"
grep -qF 'ABK_CONTROL_IOCTL_RUN_COMMAND' "$KERNEL_ROOT/common/include/linux/abk_control.h"
grep -qF 'EXPORT_SYMBOL_GPL(abk_control_get_status_json);' "$KERNEL_ROOT/common/drivers/abk_control/core.c"
grep -qF 'EXPORT_SYMBOL_GPL(abk_control_run_command);' "$KERNEL_ROOT/common/drivers/abk_control/core.c"
grep -qF 'ABK_MANAGER_CERT_SHA256' "$KERNEL_ROOT/KernelSU/kernel/Kbuild"
grep -qF 'ABK_MANAGER_CERT_SHA256' "$KERNEL_ROOT/KernelSU/kernel/manager/apk_sign.c"
grep -qF 'abk_try_register_manager' "$KERNEL_ROOT/KernelSU/kernel/manager/throne_tracker.c"
grep -qF 'ABK_CONTROL_IOCTL_GET_STATUS' "$KERNEL_ROOT/KernelSU/kernel/supercall/dispatch.c"
grep -qF 'ABK_MANAGER_CERT_SHA256' "$KERNEL_ROOT/drivers/kernelsu/manager/apk_sign.c"
grep -qF 'ABK_MANAGER_CERT_SHA256' "$KERNEL_ROOT/common/drivers/kernelsu/manager/apk_sign.c"
grep -qF 'TRACK_THRONE_FORCE_SEARCH_MGR' "$KERNEL_ROOT/common/drivers/kernelsu/manager/throne_tracker.c"
grep -qF 'ABK_CONTROL_IOCTL_GET_STATUS' "$KERNEL_ROOT/common/drivers/kernelsu/supercall/dispatch.c"
if grep -qF 'misc_register' "$KERNEL_ROOT/common/drivers/abk_control/core.c"; then
  echo "abk_control must not create a user-visible misc device" >&2
  exit 1
fi

printf 'abk_control_setup_test passed\n'
