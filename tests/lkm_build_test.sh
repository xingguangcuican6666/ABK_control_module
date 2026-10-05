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
BAKASU_REPO="$(make_fake_repo bakasu)"

assert_variant() {
  local variant="$1"
  local kmi="$2"
  local expected_url="$3"
  local expected_ref="$4"
  local expected_artifact="$5"
  local output

  output="$(LKM_REPO_URL_KERNELSU="$KERNELSU_REPO" LKM_REPO_URL_SUKISU="$SUKISU_REPO" LKM_REPO_URL_BAKASU="$BAKASU_REPO" bash "$REPO_ROOT/lkm/build.sh" --variant "$variant" --kmi "$kmi" --dry-run)"
  assert_line "$(printf '%s\t%s\t%s\t%s' "$variant" "$expected_url" "$expected_ref" "$expected_artifact")" "$output"
}

KERNELSU_PIN="08a3b087e49227c8a6731c5f1114998b5e25255b"
SUKISU_PIN="cf87e3f4ddd3f6e5464d85acf56aaa6950e70841"
BAKASU_PIN="9dbce02e511ea6b6305a238b84e456f6a92e1d0b"

assert_variant kernelsu android15-6.6 "$KERNELSU_REPO" "$KERNELSU_PIN" "$REPO_ROOT/lkm/out/kernelsu/android15-6.6_kernelsu.ko"
assert_variant sukisu android15-6.6 "$SUKISU_REPO" "$SUKISU_PIN" "$REPO_ROOT/lkm/out/sukisu/android15-6.6_kernelsu.ko"
assert_variant bakasu android16-6.12 "$BAKASU_REPO" "$BAKASU_PIN" "$REPO_ROOT/lkm/out/bakasu/android16-6.12_kernelsu.ko"

custom_out="$(LKM_REPO_URL_KERNELSU="$KERNELSU_REPO" LKM_REPO_URL_SUKISU="$SUKISU_REPO" LKM_REPO_URL_BAKASU="$BAKASU_REPO" LKM_OUT_DIR="$REPO_ROOT/custom-out" bash "$REPO_ROOT/lkm/build.sh" --variant kernelsu --kmi android14-6.1 --dry-run)"
assert_line "$(printf '%s\t%s\t%s\t%s' kernelsu "$KERNELSU_REPO" "$KERNELSU_PIN" "$REPO_ROOT/custom-out/kernelsu/android14-6.1_kernelsu.ko")" "$custom_out"

override_out="$(LKM_REPO_REF_BAKASU=deadbeef LKM_REPO_URL_KERNELSU="$KERNELSU_REPO" LKM_REPO_URL_SUKISU="$SUKISU_REPO" LKM_REPO_URL_BAKASU="$BAKASU_REPO" bash "$REPO_ROOT/lkm/build.sh" --variant bakasu --kmi android16-6.12 --dry-run)"
assert_line "$(printf '%s\t%s\t%s\t%s' bakasu "$BAKASU_REPO" deadbeef "$REPO_ROOT/lkm/out/bakasu/android16-6.12_kernelsu.ko")" "$override_out"

fake_bin="$TMP_DIR/bin"
mkdir -p "$fake_bin"
# Every KMI now builds via `CONFIG_X=y make`, so the variant flags travel in the
# environment rather than as make arguments; record both.
cat > "$fake_bin/make" <<'EOF_MAKE'
#!/usr/bin/env bash
{
  printf 'args=%s\n' "$*"
  printf 'CONFIG_KSU=%s\n' "${CONFIG_KSU-}"
  printf 'CONFIG_KSU_TRACEPOINT_HOOK=%s\n' "${CONFIG_KSU_TRACEPOINT_HOOK-}"
  printf 'CONFIG_KSU_MULTI_MANAGER_SUPPORT=%s\n' "${CONFIG_KSU_MULTI_MANAGER_SUPPORT-}"
  printf 'CC=%s\n' "${CC-}"
} > "$ABK_TEST_CAPTURE_MAKE_ARGS"
if grep -q 'xingguang_ddk' Makefile 2>/dev/null; then
  echo "unexpected xingguang_ddk-specific Makefile mutation" >&2
  exit 1
fi
printf 'fake-ko\n' > kernelsu.ko
EOF_MAKE
chmod +x "$fake_bin/make"

PATH="$fake_bin:$PATH" \
ABK_TEST_CAPTURE_MAKE_ARGS="$TMP_DIR/make.args" \
LKM_REPO_URL_KERNELSU="$KERNELSU_REPO" \
LKM_REPO_URL_SUKISU="$SUKISU_REPO" \
LKM_REPO_URL_BAKASU="$BAKASU_REPO" \
bash "$REPO_ROOT/lkm/build.sh" --variant bakasu --kmi android16-6.12 >/dev/null

make_args_path="$TMP_DIR/make.args"
[ -s "$make_args_path" ] || {
  printf 'missing captured make invocation\n' >&2
  exit 1
}
captured_make_args="$(cat "$make_args_path")"
if ! [[ "$captured_make_args" == *"CONFIG_KSU=m"* &&
    "$captured_make_args" == *"CONFIG_KSU_TRACEPOINT_HOOK=y"* &&
    "$captured_make_args" == *"CONFIG_KSU_MULTI_MANAGER_SUPPORT=y"* &&
    "$captured_make_args" == *"CC=clang"* ]]; then
  printf 'unexpected make invocation:\n%s\n' "$captured_make_args" >&2
  exit 1
fi

# Every KMI builds through the same path, so nothing may smuggle back in the per-KMI
# arch overrides that only the removed android16-7.0 job needed.
if [[ "$captured_make_args" == *"ARCH="* || "$captured_make_args" == *"LLVM=1"* ]]; then
  printf 'make args still carry per-KMI arch overrides:\n%s\n' "$captured_make_args" >&2
  exit 1
fi

list_output="$(bash "$REPO_ROOT/lkm/build.sh" --list)"
assert_line $'kernelsu\nsukisu\nbakasu' "$list_output"

# Default pins must stay identical to ABK's resolve-ksu-ref.sh Stable tier; drift here
# silently bundles an LKM built against a different kernel than the one shipped beside it.
assert_resolved_pin() {
  local variant="$1"
  local track="$2"
  local expected_ref="$3"
  local out
  # dry-run prints "<variant>\t<url>\t<ref>\t<artifact>"; the URL is overridden per
  # variant above only where a fake repo exists, so compare the ref field alone.
  out="$(bash "$REPO_ROOT/lkm/build.sh" --variant "$variant" --track "$track" --kmi android16-6.12 --dry-run | cut -f3)"
  assert_line "$expected_ref" "$out"
}

assert_resolved_pin kernelsu stable "$KERNELSU_PIN"
assert_resolved_pin sukisu stable "$SUKISU_PIN"
assert_resolved_pin bakasu stable "$BAKASU_PIN"

# Dev is a separate pin, not an alias for stable: the two are maintained independently so
# one can move without the other. They agree today, which a resolved-ref assertion cannot
# tell apart from dev silently inheriting stable's value -- so require each tier to carry
# its own literal, exactly once per variant, in lkm/build.sh.
for pin_spec in \
  "LKM_REPO_REF_KERNELSU:$KERNELSU_PIN" \
  "LKM_REPO_REF_SUKISU:$SUKISU_PIN" \
  "LKM_REPO_REF_BAKASU:$BAKASU_PIN"; do
  override="${pin_spec%%:*}"
  pin="${pin_spec##*:}"
  declared="$(grep -c -- "$override:-$pin" "$REPO_ROOT/lkm/build.sh")"
  if [ "$declared" -ne 2 ]; then
    printf 'expected 2 declarations of %s (one per tier), found %s\n' "$override" "$declared" >&2
    exit 1
  fi
done

printf 'lkm_build_test passed\n'
