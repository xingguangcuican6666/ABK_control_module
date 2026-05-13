#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$MODULE_DIR/module.conf" ]; then
  # shellcheck disable=SC1091
  source "$MODULE_DIR/module.conf"
fi

# shellcheck disable=SC1091
source "$MODULE_DIR/scripts/libabk.sh"

abk_require_env KERNEL_ROOT DEFCONFIG CUSTOM_EXTERNAL_MODULE_STAGE

abk_log "module: ${ABK_MODULE_NAME:-ABK external module}"
abk_log "version: ${ABK_MODULE_VERSION:-unknown}"
abk_log "stage: $CUSTOM_EXTERNAL_MODULE_STAGE"
abk_log "config: ${CONFIG:-unknown}"
abk_log "kernel root: $KERNEL_ROOT"

case "$CUSTOM_EXTERNAL_MODULE_STAGE" in
  after_patch)
    # Source-tree changes usually belong here.
    #
    # Examples:
    #   abk_apply_patch_dir "$MODULE_DIR/patches/common"
    #   abk_copy_into_kernel "$MODULE_DIR/files/drivers/example" "common/drivers/example"
    #
    # The template is intentionally a no-op.
    abk_log "after_patch: no changes configured"
    ;;

  before_build)
    # Final defconfig or generated-file changes usually belong here.
    #
    # Examples:
    #   abk_enable_config CONFIG_EXAMPLE_FEATURE
    #   abk_disable_config CONFIG_UNUSED_FEATURE
    #
    # The template is intentionally a no-op.
    abk_log "before_build: no changes configured"
    ;;

  *)
    abk_die "unsupported CUSTOM_EXTERNAL_MODULE_STAGE: $CUSTOM_EXTERNAL_MODULE_STAGE"
    ;;
esac

abk_log "done"
