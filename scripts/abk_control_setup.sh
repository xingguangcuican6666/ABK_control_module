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

abk_control_record_manifest_entry() {
  local records_file="$1"
  local id="$2"
  local name="$3"
  local version="$4"
  local description="$5"
  local repo_url="$6"
  local stage="$7"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$name" "$version" "$description" "$repo_url" "$stage" >> "$records_file"
}

abk_control_emit_manifest_entry() {
  local entries_file="$1"
  local id="$2"
  local name="$3"
  local version="$4"
  local description="$5"
  local repo_url="$6"
  local stages="$7"

  {
    printf '\t{\n'
    printf '\t\t.id = "%s",\n' "$(abk_control_c_escape "$id")"
    printf '\t\t.name = "%s",\n' "$(abk_control_c_escape "$name")"
    printf '\t\t.version = "%s",\n' "$(abk_control_c_escape "$version")"
    printf '\t\t.description = "%s",\n' "$(abk_control_c_escape "$description")"
    printf '\t\t.repo_url = "%s",\n' "$(abk_control_c_escape "$repo_url")"
    printf '\t\t.stage = "%s",\n' "$(abk_control_c_escape "$stages")"
    printf '\t},\n'
  } >> "$entries_file"
}

abk_control_collect_manifest_entry() {
  local records_file="$1"
  local stage="$2"
  local module_dir="$3"
  local repo_url="$4"
  local conf_file="$module_dir/module.conf"
  local id name version description

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

  abk_control_record_manifest_entry \
    "$records_file" \
    "$id" \
    "$name" \
    "$version" \
    "$description" \
    "$repo_url" \
    "$stage"
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
  local seen_file id name version description repo_url stage
  local id2 _name2 _version2 _description2 _repo_url2 stage2
  local stages entry_count

  seen_file="$(mktemp)"
  entry_count=0

  while IFS=$'\t' read -r id name version description repo_url stage || [ -n "$id$name$version$description$repo_url$stage" ]; do
    [ -n "$id" ] || continue
    if grep -Fqx "$id" "$seen_file"; then
      continue
    fi
    printf '%s\n' "$id" >> "$seen_file"

    stages="$stage"
    while IFS=$'\t' read -r id2 _name2 _version2 _description2 _repo_url2 stage2 || [ -n "$id2$_name2$_version2$_description2$_repo_url2$stage2" ]; do
      [ "$id2" = "$id" ] || continue
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
      "$stages"
    entry_count=$((entry_count + 1))
  done < "$records_file"

  rm -f "$seen_file"
  printf '%s\n' "$entry_count"
}

abk_control_generate_manifest_source() {
  local common_dir output records_file entries_file manifest entry_count raw_count tmp_output
  local stage module_dir repo_url

  common_dir="$(abk_control_common_dir)"
  output="$common_dir/drivers/abk_control/abk_control_manifest.c"
  manifest="${CUSTOM_EXTERNAL_MODULES_MANIFEST:-}"
  records_file="$(mktemp)"
  entries_file="$(mktemp)"
  tmp_output="$(mktemp)"
  raw_count=0
  entry_count=0

  if [ -n "$manifest" ] && [ -s "$manifest" ]; then
    while IFS=$'\t' read -r stage module_dir repo_url || [ -n "$stage$module_dir$repo_url" ]; do
      [ -n "$stage" ] && [ -n "$module_dir" ] && [ -n "$repo_url" ] || continue
      if abk_control_collect_manifest_entry "$records_file" "$stage" "$module_dir" "$repo_url"; then
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

  mv "$tmp_output" "$output"
  rm -f "$records_file" "$entries_file"
  abk_log "generated $output with $entry_count metadata entries"
}

abk_control_enable_config() {
  abk_enable_config CONFIG_ABK_CONTROL
}
