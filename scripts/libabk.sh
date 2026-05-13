#!/usr/bin/env bash

abk_log() {
  printf '[ABK module] %s\n' "$*"
}

abk_warn() {
  printf '[ABK module][warn] %s\n' "$*" >&2
}

abk_die() {
  printf '[ABK module][error] %s\n' "$*" >&2
  exit 1
}

abk_require_env() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      abk_die "required environment variable is empty: $name"
    fi
  done
}

abk_common_dir() {
  abk_require_env KERNEL_ROOT
  printf '%s/common\n' "$KERNEL_ROOT"
}

abk_require_file() {
  local path="$1"
  [ -f "$path" ] || abk_die "required file not found: $path"
}

abk_require_dir() {
  local path="$1"
  [ -d "$path" ] || abk_die "required directory not found: $path"
}

abk_kernel_make_value() {
  local key="$1"
  local makefile
  makefile="$(abk_common_dir)/Makefile"
  abk_require_file "$makefile"
  awk -v key="$key" '$1 == key && $2 == "=" { print $3; exit }' "$makefile"
}

abk_kernel_version() {
  local version patchlevel sublevel
  version="$(abk_kernel_make_value VERSION)"
  patchlevel="$(abk_kernel_make_value PATCHLEVEL)"
  sublevel="$(abk_kernel_make_value SUBLEVEL)"
  printf '%s.%s.%s\n' "$version" "$patchlevel" "$sublevel"
}

abk_stage_is() {
  local expected="$1"
  [ "${CUSTOM_EXTERNAL_MODULE_STAGE:-}" = "$expected" ]
}

abk_config_line() {
  local symbol="$1"
  local value="$2"
  symbol="${symbol#CONFIG_}"

  case "$value" in
    n)
      printf '# CONFIG_%s is not set\n' "$symbol"
      ;;
    y|m)
      printf 'CONFIG_%s=%s\n' "$symbol" "$value"
      ;;
    \"*\")
      printf 'CONFIG_%s=%s\n' "$symbol" "$value"
      ;;
    *)
      printf 'CONFIG_%s=%s\n' "$symbol" "$value"
      ;;
  esac
}

abk_set_config() {
  local symbol="$1"
  local value="$2"
  local file="${3:-${DEFCONFIG:-}}"
  local clean_symbol
  local tmp

  [ -n "$file" ] || abk_die "DEFCONFIG is empty and no config file was provided"
  abk_require_file "$file"

  clean_symbol="${symbol#CONFIG_}"
  tmp="$(mktemp)"

  grep -v -E "^(CONFIG_${clean_symbol}=|# CONFIG_${clean_symbol} is not set$)" "$file" > "$tmp" || true
  abk_config_line "$clean_symbol" "$value" >> "$tmp"
  mv "$tmp" "$file"

  abk_log "set CONFIG_${clean_symbol}=$value in $file"
}

abk_enable_config() {
  abk_set_config "$1" y "${2:-${DEFCONFIG:-}}"
}

abk_module_config() {
  abk_set_config "$1" m "${2:-${DEFCONFIG:-}}"
}

abk_disable_config() {
  abk_set_config "$1" n "${2:-${DEFCONFIG:-}}"
}

abk_append_line_once() {
  local file="$1"
  local line="$2"

  abk_require_file "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
    abk_log "append line to $file: $line"
  fi
}

abk_apply_patch() {
  local patch_file="$1"
  local target_dir="${2:-$(abk_common_dir)}"

  abk_require_file "$patch_file"
  abk_require_dir "$target_dir"

  (
    cd "$target_dir" || exit
    if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
      abk_log "patch already applied: $patch_file"
      exit 0
    fi

    if ! git apply --check "$patch_file"; then
      abk_die "patch does not apply: $patch_file"
    fi

    git apply "$patch_file"
    abk_log "applied patch: $patch_file"
  )
}

abk_apply_patch_dir() {
  local patch_dir="$1"
  local target_dir="${2:-$(abk_common_dir)}"
  local patch

  [ -d "$patch_dir" ] || {
    abk_warn "patch directory not found, skip: $patch_dir"
    return 0
  }

  while IFS= read -r patch; do
    abk_apply_patch "$patch" "$target_dir"
  done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | sort)
}

abk_copy_into_kernel() {
  local source_path="$1"
  local relative_target="$2"
  local target_path

  abk_require_env KERNEL_ROOT
  [ -e "$source_path" ] || abk_die "source path not found: $source_path"

  target_path="$KERNEL_ROOT/$relative_target"
  mkdir -p "$(dirname "$target_path")"
  cp -a "$source_path" "$target_path"
  abk_log "copied $source_path -> $target_path"
}
