#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$MODULE_DIR/module.conf" ]; then
  # shellcheck disable=SC1091
  source "$MODULE_DIR/module.conf"
fi

# shellcheck disable=SC1091
source "$MODULE_DIR/scripts/libabk.sh"
# shellcheck disable=SC1091
source "$MODULE_DIR/scripts/abk_control_setup.sh"

abk_require_env KERNEL_ROOT DEFCONFIG CUSTOM_EXTERNAL_MODULE_STAGE

abk_log "module: ${ABK_MODULE_NAME:-ABK external module}"
abk_log "version: ${ABK_MODULE_VERSION:-unknown}"
abk_log "stage: $CUSTOM_EXTERNAL_MODULE_STAGE"
abk_log "config: ${CONFIG:-unknown}"
abk_log "kernel root: $KERNEL_ROOT"

case "$CUSTOM_EXTERNAL_MODULE_STAGE" in
  after_patch)
    abk_log "after_patch: installing ABK control kernel sources"
    abk_control_install_kernel_files
    abk_control_patch_ksu_bridge
    ;;

  before_build)
    abk_log "before_build: installing ABK control kernel sources"
    abk_control_install_kernel_files
    abk_control_generate_manifest_source
    abk_control_enable_config
    abk_control_validate_kernel_bridge
    ;;

  *)
    abk_die "unsupported CUSTOM_EXTERNAL_MODULE_STAGE: $CUSTOM_EXTERNAL_MODULE_STAGE"
    ;;
esac

abk_log "done"
