#!/usr/bin/env bash

abk_control_common_dir() {
  abk_common_dir
}

abk_control_copy_tree() {
  local source_dir="$1"
  local target_dir="$2"

  abk_require_dir "$source_dir"
  mkdir -p "$target_dir"
  cp -a "$source_dir"/. "$target_dir"/
  abk_log "synced $source_dir -> $target_dir"
}

abk_control_copy_file() {
  local source_file="$1"
  local target_file="$2"

  abk_require_file "$source_file"
  mkdir -p "$(dirname "$target_file")"
  cp -a "$source_file" "$target_file"
  abk_log "copied $source_file -> $target_file"
}

abk_control_install_kernel_files() {
  local common_dir

  common_dir="$(abk_control_common_dir)"
  abk_require_dir "$common_dir/drivers"
  abk_require_dir "$common_dir/include/linux"
  abk_require_file "$common_dir/drivers/Kconfig"
  abk_require_file "$common_dir/drivers/Makefile"

  abk_control_copy_tree \
    "$MODULE_DIR/files/drivers/abk_control" \
    "$common_dir/drivers/abk_control"
  abk_control_copy_file \
    "$MODULE_DIR/files/include/linux/abk_control.h" \
    "$common_dir/include/linux/abk_control.h"

  abk_append_line_once "$common_dir/drivers/Kconfig" 'source "drivers/abk_control/Kconfig"'
  abk_append_line_once "$common_dir/drivers/Makefile" 'obj-$(CONFIG_ABK_CONTROL) += abk_control/'
}

abk_control_patch_ksu_bridge() {
  MODULE_DIR="$MODULE_DIR" python3 "$MODULE_DIR/scripts/abk_control_ksu_patch.py"
}

abk_control_conf_value() {
  local file="$1"
  local key="$2"

  [ -f "$file" ] || return 0
  awk -v target="$key" '
    function trim(value) {
      sub(/^[ \t\r\n]+/, "", value)
      sub(/[ \t\r\n]+$/, "", value)
      return value
    }
    /^[ \t]*#/ { next }
    {
      line = $0
      sub(/\r$/, "", line)
      eq = index(line, "=")
      if (!eq) next
      key = trim(substr(line, 1, eq - 1))
      if (key != target) next
      value = trim(substr(line, eq + 1))
      if (value ~ /^".*"$/) value = substr(value, 2, length(value) - 2)
      print value
      exit
    }
  ' "$file"
}

abk_control_id_from_text() {
  local raw="$1"

  raw="${raw##*/}"
  raw="${raw%.git}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | sed 's/[^a-z0-9_.-]/_/g; s/^_*//; s/_*$//')"
  printf '%s\n' "${raw:-abk_module}"
}

abk_control_c_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

abk_control_bool_literal() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    1|y|yes|true|on) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

abk_control_work_mode() {
  case "$(printf '%s' "${ABK_BUILD_WORK_MODE:-built-in}" | tr '[:upper:]' '[:lower:]')" in
    lkm) printf 'lkm\n' ;;
    builtin|built-in|built_in) printf 'built-in\n' ;;
    *) printf 'built-in\n' ;;
  esac
}

abk_control_abk_root() {
  if [ -n "${ZZH_PATCHES:-}" ] && [ -d "$ZZH_PATCHES" ]; then
    printf '%s\n' "$ZZH_PATCHES"
  elif [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ]; then
    printf '%s\n' "$GITHUB_WORKSPACE"
  else
    printf '%s\n' "$PWD"
  fi
}

abk_control_abk_version() {
  local root build_file

  root="$(abk_control_abk_root)"
  build_file="$root/app/build.gradle.kts"
  if [ -f "$build_file" ]; then
    sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$build_file" | head -1
  fi
}

abk_control_abk_commit() {
  local root

  root="$(abk_control_abk_root)"
  if [ -d "$root/.git" ]; then
    git -C "$root" rev-parse --short HEAD 2>/dev/null || true
  fi
}

abk_control_emit_build_info() {
  local output_file="$1"
  local abk_version abk_commit

  abk_version="$(abk_control_abk_version)"
  abk_commit="$(abk_control_abk_commit)"

  {
    printf '\nconst struct abk_control_build_info abk_control_build = {\n'
    printf '\t.abk_version = "%s",\n' "$(abk_control_c_escape "$abk_version")"
    printf '\t.abk_commit = "%s",\n' "$(abk_control_c_escape "$abk_commit")"
    printf '\t.work_mode = "%s",\n' "$(abk_control_c_escape "$(abk_control_work_mode)")"
    printf '\t.android_version = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_ANDROID_VERSION:-}")"
    printf '\t.kernel_version = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_KERNEL_VERSION:-}")"
    printf '\t.sub_level = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_SUB_LEVEL:-}")"
    printf '\t.os_patch_level = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_OS_PATCH_LEVEL:-}")"
    printf '\t.revision = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_REVISION:-}")"
    printf '\t.kernelsu_variant = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_KSU_VARIANT:-}")"
    printf '\t.kernelsu_branch = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_KSU_BRANCH:-}")"
    printf '\t.version = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_VERSION:-}")"
    printf '\t.build_time = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_TIME:-}")"
    printf '\t.virtualization_support = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_VIRTUALIZATION_SUPPORT:-}")"
    printf '\t.zram_extra_algos = "%s",\n' "$(abk_control_c_escape "${ABK_BUILD_ZRAM_EXTRA_ALGOS:-}")"
    printf '\t.features = {\n'
    printf '\t\t.use_zram = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_USE_ZRAM:-false}")"
    printf '\t\t.use_bbg = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_USE_BBG:-false}")"
    printf '\t\t.use_ddk = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_USE_DDK:-false}")"
    printf '\t\t.use_ntsync = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_USE_NTSYNC:-false}")"
    printf '\t\t.use_networking = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_USE_NETWORKING:-false}")"
    printf '\t\t.use_kpm = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_USE_KPM:-false}")"
    printf '\t\t.use_rekernel = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_USE_REKERNEL:-false}")"
    printf '\t\t.enable_susfs = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_ENABLE_SUSFS:-false}")"
    printf '\t\t.supp_op = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_SUPP_OP:-false}")"
    printf '\t\t.zram_full_algo = %s,\n' "$(abk_control_bool_literal "${ABK_FEATURE_ZRAM_FULL_ALGO:-false}")"
    printf '\t},\n'
    printf '};\n'
  } >> "$output_file"
}

abk_control_record_manifest_entry() {
  local records_file="$1"
  local id="$2"
  local name="$3"
  local version="$4"
  local description="$5"
  local repo_url="$6"
  local stage="$7"
  local group_id="$8"
  local group_name="$9"
  local group_role="${10}"
  local group_description="${11}"
  local group_repo_url="${12}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$name" "$version" "$description" "$repo_url" "$stage" \
    "$group_id" "$group_name" "$group_role" "$group_description" "$group_repo_url" >> "$records_file"
}

abk_control_emit_manifest_entry() {
  local entries_file="$1"
  local id="$2"
  local name="$3"
  local version="$4"
  local description="$5"
  local repo_url="$6"
  local stages="$7"
  local group_id="$8"
  local group_name="$9"
  local group_role="${10}"
  local group_description="${11}"
  local group_repo_url="${12}"

  {
    printf '\t{\n'
    printf '\t\t.id = "%s",\n' "$(abk_control_c_escape "$id")"
    printf '\t\t.name = "%s",\n' "$(abk_control_c_escape "$name")"
    printf '\t\t.version = "%s",\n' "$(abk_control_c_escape "$version")"
    printf '\t\t.description = "%s",\n' "$(abk_control_c_escape "$description")"
    printf '\t\t.repo_url = "%s",\n' "$(abk_control_c_escape "$repo_url")"
    printf '\t\t.stage = "%s",\n' "$(abk_control_c_escape "$stages")"
    printf '\t\t.group_id = "%s",\n' "$(abk_control_c_escape "$group_id")"
    printf '\t\t.group_name = "%s",\n' "$(abk_control_c_escape "$group_name")"
    printf '\t\t.group_role = "%s",\n' "$(abk_control_c_escape "$group_role")"
    printf '\t\t.group_description = "%s",\n' "$(abk_control_c_escape "$group_description")"
    printf '\t\t.group_repo_url = "%s",\n' "$(abk_control_c_escape "$group_repo_url")"
    printf '\t},\n'
  } >> "$entries_file"
}

abk_control_conf_or_fallback() {
  local file="$1"
  local primary="$2"
  local fallback="$3"
  local value

  value="$(abk_control_conf_value "$file" "$primary")"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    abk_control_conf_value "$file" "$fallback"
  fi
}

abk_control_collect_manifest_entry() {
  local records_file="$1"
  local stage="$2"
  local module_dir="$3"
  local repo_url="$4"
  local entry_kind="${5:-module}"
  local group_repo_url="${6:-}"
  local child_id="${7:-}"
  local conf_file="$module_dir/module.conf"
  local id name version description group_id group_name group_role group_description

  if [ ! -f "$conf_file" ]; then
    abk_warn "module.conf not found, skip metadata: $repo_url"
    return 1
  fi

  name="$(abk_control_conf_value "$conf_file" ABK_MODULE_NAME)"
  if [ -z "$name" ]; then
    abk_warn "ABK_MODULE_NAME is empty, skip metadata: $repo_url"
    return 1
  fi

  id="$(abk_control_conf_value "$conf_file" ABK_MODULE_ID)"
  [ -n "$id" ] || id="$(abk_control_id_from_text "$repo_url")"
  version="$(abk_control_conf_value "$conf_file" ABK_MODULE_VERSION)"
  description="$(abk_control_conf_value "$conf_file" ABK_MODULE_DESCRIPTION)"
  group_id=""
  group_name=""
  group_role=""
  group_description=""

  if [ "$entry_kind" = "module_set_child" ]; then
    if [ -n "$child_id" ] && [ "$child_id" != "$id" ]; then
      abk_warn "module child id mismatch, prefer workflow child id: $child_id -> $id ($repo_url)"
    fi
    group_id="$(abk_control_conf_or_fallback "$conf_file" ABK_MODULE_GROUP_ID ABK_MODULE_SET_ID)"
    group_name="$(abk_control_conf_or_fallback "$conf_file" ABK_MODULE_GROUP_NAME ABK_MODULE_SET_NAME)"
    group_role="$(abk_control_conf_value "$conf_file" ABK_MODULE_GROUP_ROLE)"
    group_description="$(abk_control_conf_or_fallback "$conf_file" ABK_MODULE_GROUP_DESCRIPTION ABK_MODULE_SET_DESCRIPTION)"
  fi

  abk_control_record_manifest_entry \
    "$records_file" \
    "$id" \
    "$name" \
    "$version" \
    "$description" \
    "$repo_url" \
    "$stage" \
    "$group_id" \
    "$group_name" \
    "$group_role" \
    "$group_description" \
    "$group_repo_url"
}

abk_control_stage_list_contains() {
  local stages="$1"
  local stage="$2"

  case ",$stages," in
    *,"$stage",*) return 0 ;;
    *) return 1 ;;
  esac
}

abk_control_emit_merged_manifest_entries() {
  local records_file="$1"
  local entries_file="$2"
  local seen_file id name version description repo_url stage group_id group_name group_role group_description group_repo_url
  local id2 _name2 _version2 _description2 _repo_url2 stage2 _group_id2 _group_name2 _group_role2 _group_description2 _group_repo_url2
  local stages entry_count

  seen_file="$(mktemp)"
  entry_count=0

  while IFS=$'\t' read -r id name version description repo_url stage group_id group_name group_role group_description group_repo_url || [ -n "$id$name$version$description$repo_url$stage$group_id$group_name$group_role$group_description$group_repo_url" ]; do
    [ -n "$id" ] || continue
    if grep -Fqx "${id}|${group_id}|${group_repo_url}" "$seen_file"; then
      continue
    fi
    printf '%s|%s|%s\n' "$id" "$group_id" "$group_repo_url" >> "$seen_file"

    stages="$stage"
    while IFS=$'\t' read -r id2 _name2 _version2 _description2 _repo_url2 stage2 _group_id2 _group_name2 _group_role2 _group_description2 _group_repo_url2 || [ -n "$id2$_name2$_version2$_description2$_repo_url2$stage2$_group_id2$_group_name2$_group_role2$_group_description2$_group_repo_url2" ]; do
      [ "$id2" = "$id" ] || continue
      [ "$_group_id2" = "$group_id" ] || continue
      [ "$_group_repo_url2" = "$group_repo_url" ] || continue
      if ! abk_control_stage_list_contains "$stages" "$stage2"; then
        stages="${stages},${stage2}"
      fi
    done < "$records_file"

    abk_control_emit_manifest_entry \
      "$entries_file" \
      "$id" \
      "$name" \
      "$version" \
      "$description" \
      "$repo_url" \
      "$stages" \
      "$group_id" \
      "$group_name" \
      "$group_role" \
      "$group_description" \
      "$group_repo_url"
    entry_count=$((entry_count + 1))
  done < "$records_file"

  rm -f "$seen_file"
  printf '%s\n' "$entry_count"
}

abk_control_generate_manifest_source() {
  local common_dir output records_file entries_file manifest entry_count raw_count tmp_output
  local stage module_dir repo_url entry_kind group_repo_url child_id

  common_dir="$(abk_control_common_dir)"
  output="$common_dir/drivers/abk_control/abk_control_manifest.c"
  manifest="${CUSTOM_EXTERNAL_MODULES_MANIFEST:-}"
  records_file="$(mktemp)"
  entries_file="$(mktemp)"
  tmp_output="$(mktemp)"
  raw_count=0
  entry_count=0

  if [ -n "$manifest" ] && [ -s "$manifest" ]; then
    while IFS=$'\t' read -r stage module_dir repo_url entry_kind group_repo_url child_id || [ -n "$stage$module_dir$repo_url$entry_kind$group_repo_url$child_id" ]; do
      [ -n "$stage" ] && [ -n "$module_dir" ] && [ -n "$repo_url" ] || continue
      if abk_control_collect_manifest_entry "$records_file" "$stage" "$module_dir" "$repo_url" "${entry_kind:-module}" "${group_repo_url:-}" "${child_id:-}"; then
        raw_count=$((raw_count + 1))
      fi
    done < "$manifest"
  fi

  if [ "$raw_count" -eq 0 ]; then
    if abk_control_collect_manifest_entry \
      "$records_file" \
      "${CUSTOM_EXTERNAL_MODULE_STAGE:-before_build}" \
      "$MODULE_DIR" \
      "${ABK_MODULE_REPO_URL:-local:ABK_control_module}"; then
      raw_count=1
    fi
  fi

  entry_count="$(abk_control_emit_merged_manifest_entries "$records_file" "$entries_file")"

  {
    printf '// SPDX-License-Identifier: GPL-2.0\n'
    printf '#include <linux/abk_control.h>\n\n'
    printf 'const struct abk_control_manifest_entry abk_control_manifest[] = {\n'
    cat "$entries_file"
    printf '};\n\n'
    printf 'const size_t abk_control_manifest_count = %s;\n' "$entry_count"
  } > "$tmp_output"
  abk_control_emit_build_info "$tmp_output"

  mv "$tmp_output" "$output"
  rm -f "$records_file" "$entries_file"
  abk_log "generated $output with $entry_count metadata entries"
}

abk_control_enable_config() {
  abk_enable_config CONFIG_ABK_CONTROL
}

abk_control_validate_kernel_bridge() {
  abk_control_patch_ksu_bridge
}
