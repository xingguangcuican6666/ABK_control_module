#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

assert_line() {
  local expected="$1"
  local actual="$2"

  if [ "$expected" != "$actual" ]; then
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

make_fake_repo() {
  local name="$1"
  local repo="$TMP_DIR/$name"
  mkdir -p "$repo/kernel/manager" "$repo/kernel/supercall" "$repo/kernel/policy"
  cat > "$repo/kernel/Kbuild" <<'EOF_KBUILD'
obj-$(CONFIG_KSU) += kernelsu.o
EOF_KBUILD
  cat > "$repo/kernel/manager/apk_sign.c" <<'EOF_APK'
#define CERT_MAX_LENGTH 1024
bool is_manager_apk(char *path)
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
  cat > "$repo/kernel/manager/manager_identity.h" <<'EOF_ID'
#ifndef __KSU_H_MANAGER_IDENTITY
#define __KSU_H_MANAGER_IDENTITY

#ifdef CONFIG_KSU_DISABLE_MANAGER
static inline bool ksu_is_manager_appid_valid()
{
    return true;
}

static inline bool is_manager()
{
    return current_uid().val == 0;
}

static inline bool is_uid_manager(uid_t uid)
{
    return uid == 0;
}

static inline uid_t ksu_get_manager_appid()
{
    return 0;
}

static inline void ksu_set_manager_appid(uid_t appid)
{
    (void)appid;
}

static inline void ksu_invalidate_manager_uid()
{
}
#else
extern uid_t ksu_manager_appid; // DO NOT DIRECT USE

static inline bool ksu_is_manager_appid_valid()
{
    return ksu_manager_appid != KSU_INVALID_APPID;
}
static inline bool is_manager()
{
    return unlikely(ksu_manager_appid == current_uid().val % KSU_PER_USER_RANGE);
}
static inline bool is_uid_manager(uid_t uid)
{
    return unlikely(ksu_manager_appid == uid % KSU_PER_USER_RANGE);
}
static inline uid_t ksu_get_manager_appid()
{
    return ksu_manager_appid;
}
static inline void ksu_set_manager_appid(uid_t appid)
{
    ksu_manager_appid = appid;
}
static inline void ksu_invalidate_manager_uid()
{
    ksu_manager_appid = KSU_INVALID_APPID;
}
#endif

#endif
EOF_ID
  cat > "$repo/kernel/manager/throne_tracker.h" <<'EOF_TH'
#ifndef __KSU_H_UID_OBSERVER
#define __KSU_H_UID_OBSERVER
#ifdef CONFIG_KSU_DISABLE_MANAGER
static inline void track_throne(bool prune_only)
{
}
#else
void track_throne(bool prune_only);
#endif
#endif
EOF_TH
  cat > "$repo/kernel/manager/throne_tracker.c" <<'EOF_TC'
#include <linux/list.h>
#define SYSTEM_PACKAGES_LIST_PATH "/data/system/packages.list"
uid_t ksu_manager_appid = KSU_INVALID_APPID;
struct uid_data {
    struct list_head list;
    u32 uid;
    char package[KSU_MAX_PACKAGE_NAME];
};
static void crown_manager(const char *apk, struct list_head *uid_data)
{
    char pkg[KSU_MAX_PACKAGE_NAME];
    if (get_pkg_from_apk_path(pkg, apk) < 0) {
        return;
    }
    ksu_set_manager_appid(10000);
}
void search_manager(const char *path, int depth, struct list_head *uid_data)
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
    struct list_head uid_list;
    INIT_LIST_HEAD(&uid_list);

    struct uid_data *np;
    struct uid_data *n;

    if (prune_only)
        goto prune;

    // first, check if manager_uid exist!
    bool manager_exist = false;
    list_for_each_entry (np, &uid_list, list) {
        if (np->uid == ksu_get_manager_appid()) {
            manager_exist = true;
            break;
        }
    }

    if (!manager_exist) {
        if (ksu_is_manager_appid_valid()) {
            pr_info("manager is uninstalled, invalidate it!\n");
            ksu_invalidate_manager_uid();
            goto prune;
        }
        pr_info("Searching manager...\n");
        search_manager("/data/app", 2, &uid_list);
        pr_info("Search manager finished\n");
    }

prune:
out:
    list_for_each_entry_safe (np, n, &uid_list, list) {
        list_del(&np->list);
        kfree(np);
    }
}
void __init ksu_throne_tracker_init()
{
}
EOF_TC
  cat > "$repo/kernel/policy/allowlist.c" <<'EOF_AL'
bool ksu_uid_should_umount(uid_t uid)
{
    if (likely(ksu_is_manager_appid_valid()) && unlikely(ksu_get_manager_appid() == uid % PER_USER_RANGE)) {
        return false;
    }
    return true;
}
EOF_AL
  cat > "$repo/kernel/supercall/dispatch.c" <<'EOF_DIS'
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
EOF_DIS
  (
    cd "$repo"
    git init -q
    git add .
    git -c user.name=test -c user.email=test@example.invalid commit -q -m init
  )
  printf '%s\n' "$repo"
}

KERNELSU_REPO="$(make_fake_repo kernelsu)"
SUKISU_REPO="$(make_fake_repo sukisu)"
RESUKISU_REPO="$(make_fake_repo resukisu)"

assert_variant() {
  local variant="$1"
  local kmi="$2"
  local expected_url="$3"
  local expected_artifact="$4"
  local output

  output="$(LKM_REPO_URL_KERNELSU="$KERNELSU_REPO" LKM_REPO_URL_SUKISU="$SUKISU_REPO" LKM_REPO_URL_RESUKISU="$RESUKISU_REPO" bash "$REPO_ROOT/lkm/build.sh" --variant "$variant" --kmi "$kmi" --dry-run)"
  assert_line "$(printf '%s\t%s\t%s' "$variant" "$expected_url" "$expected_artifact")" "$output"
}

assert_variant kernelsu android15-6.6 "$KERNELSU_REPO" "$REPO_ROOT/lkm/out/kernelsu/android15-6.6_kernelsu.ko"
assert_variant sukisu android15-6.6 "$SUKISU_REPO" "$REPO_ROOT/lkm/out/sukisu/android15-6.6_kernelsu.ko"
assert_variant resukisu android16-6.12 "$RESUKISU_REPO" "$REPO_ROOT/lkm/out/resukisu/android16-6.12_kernelsu.ko"

custom_out="$(LKM_REPO_URL_KERNELSU="$KERNELSU_REPO" LKM_REPO_URL_SUKISU="$SUKISU_REPO" LKM_REPO_URL_RESUKISU="$RESUKISU_REPO" LKM_OUT_DIR="$REPO_ROOT/custom-out" bash "$REPO_ROOT/lkm/build.sh" --variant kernelsu --kmi android14-6.1 --dry-run)"
assert_line "$(printf '%s\t%s\t%s' kernelsu "$KERNELSU_REPO" "$REPO_ROOT/custom-out/kernelsu/android14-6.1_kernelsu.ko")" "$custom_out"

fake_bin="$TMP_DIR/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/make" <<'EOF_MAKE'
#!/usr/bin/env bash
printf 'fake-ko\n' > kernelsu.ko
EOF_MAKE
chmod +x "$fake_bin/make"

PATH="$fake_bin:$PATH" \
LKM_REPO_URL_KERNELSU="$KERNELSU_REPO" \
LKM_REPO_URL_SUKISU="$SUKISU_REPO" \
LKM_REPO_URL_RESUKISU="$RESUKISU_REPO" \
bash "$REPO_ROOT/lkm/build.sh" --variant kernelsu --kmi android15-6.6 --patch-only >/dev/null

list_output="$(bash "$REPO_ROOT/lkm/build.sh" --list)"
assert_line $'kernelsu\nsukisu\nresukisu' "$list_output"

printf 'lkm_build_test passed\n'
