#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_OUT_DIR="$ROOT_DIR/lkm/out"

usage() {
  cat <<'EOF'
usage: lkm/build.sh [--variant NAME|all] [--kmi KMI] [--out-dir PATH] [--dry-run] [--patch-only] [--no-abk-manager] [--list]

variants:
  kernelsu
  sukisu
  resukisu

The build clones the upstream source at runtime, patches it with the ABK
manager bridge by default, and then produces kernelsu.ko.
EOF
}

die() {
  printf '[lkm] %s\n' "$*" >&2
  exit 1
}

variant_repo_url() {
  case "$1" in
    kernelsu)
      printf '%s\n' "${LKM_REPO_URL_KERNELSU:-https://github.com/tiann/KernelSU.git}"
      ;;
    sukisu)
      printf '%s\n' "${LKM_REPO_URL_SUKISU:-https://github.com/SukiSU-Ultra/SukiSU-Ultra.git}"
      ;;
    resukisu)
      printf '%s\n' "${LKM_REPO_URL_RESUKISU:-https://github.com/ReSukiSU/ReSukiSU.git}"
      ;;
    *)
      return 1
      ;;
  esac
}

variant_repo_ref() {
  case "$1" in
    kernelsu)
      printf '%s\n' "${LKM_REPO_REF_KERNELSU:-}"
      ;;
    sukisu)
      printf '%s\n' "${LKM_REPO_REF_SUKISU:-}"
      ;;
    resukisu)
      printf '%s\n' "${LKM_REPO_REF_RESUKISU:-}"
      ;;
    *)
      return 1
      ;;
  esac
}

strip_artifact() {
  local artifact="$1"

  if command -v llvm-strip >/dev/null 2>&1; then
    llvm-strip -d "$artifact" >/dev/null 2>&1 || llvm-strip "$artifact" >/dev/null 2>&1 || true
  elif command -v llvm-objcopy >/dev/null 2>&1; then
    llvm-objcopy --strip-unneeded --discard-locals "$artifact" >/dev/null 2>&1 || true
  fi
}

TMP_DIRS=()

cleanup_tmp_dirs() {
  local tmp_dir

  for tmp_dir in "${TMP_DIRS[@]}"; do
    [ -n "$tmp_dir" ] || continue
    rm -rf "$tmp_dir"
  done
}

trap cleanup_tmp_dirs EXIT

clone_variant_source() {
  local variant="$1"
  local repo_url="$2"
  local repo_ref="$3"
  local build_root

  build_root="$(mktemp -d "${TMPDIR:-/tmp}/abk-lkm-${variant}.XXXXXX")"
  if [ -n "$repo_ref" ]; then
    git clone --depth 1 --single-branch "$repo_url" "$build_root" >/dev/null
    git -C "$build_root" checkout -q "$repo_ref"
  else
    git clone --depth 1 --single-branch "$repo_url" "$build_root" >/dev/null
  fi
  TMP_DIRS+=("$build_root")
  printf '%s\n' "$build_root"
}

patch_abk_manager() {
  local build_root="$1"

  MODULE_DIR="$ROOT_DIR" KERNEL_ROOT="$build_root" \
    python3 "$ROOT_DIR/scripts/abk_control_ksu_patch.py"
}

VARIANT="${LKM_VARIANT:-all}"
KMI="${LKM_KMI:-${DDK_TARGET:-}}"
OUT_DIR="${LKM_OUT_DIR:-$DEFAULT_OUT_DIR}"
DRY_RUN=0
PATCH_ONLY=0
PATCH_ABK_MANAGER="${LKM_PATCH_ABK_MANAGER:-1}"
FRAME_WARN_KCFLAGS="${LKM_FRAME_WARN_KCFLAGS:--Wno-frame-larger-than}"

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)
      [ $# -ge 2 ] || die "--variant needs a value"
      VARIANT="$2"
      shift 2
      ;;
    --kmi)
      [ $# -ge 2 ] || die "--kmi needs a value"
      KMI="$2"
      shift 2
      ;;
    --out-dir)
      [ $# -ge 2 ] || die "--out-dir needs a value"
      OUT_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --patch-only)
      PATCH_ONLY=1
      shift
      ;;
    --no-abk-manager)
      PATCH_ABK_MANAGER=0
      shift
      ;;
    --list)
      printf '%s\n' kernelsu sukisu resukisu
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$KMI" ] || die "missing --kmi or LKM_KMI/DDK_TARGET"

if [ "$VARIANT" = "all" ]; then
  variants="kernelsu sukisu resukisu"
else
  variants="$VARIANT"
fi

for variant in $variants; do
  repo_url="$(variant_repo_url "$variant")" || die "unsupported variant: $variant"
  repo_ref="$(variant_repo_ref "$variant")" || die "unsupported variant: $variant"
  artifact_dir="$OUT_DIR/$variant"
  artifact="$artifact_dir/${KMI}_kernelsu.ko"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\t%s\t%s\n' "$variant" "$repo_url" "$artifact"
    continue
  fi

  mkdir -p "$artifact_dir"

  build_root="$(clone_variant_source "$variant" "$repo_url" "$repo_ref")"
  build_dir="$build_root/kernel"
  [ -d "$build_dir" ] || die "cloned source missing kernel directory: $build_dir"

  if [ "$PATCH_ABK_MANAGER" != "0" ]; then
    patch_abk_manager "$build_root"
  fi

  if [ "$PATCH_ONLY" -eq 1 ]; then
    printf '[lkm] patched %s from %s\n' "$variant" "$repo_url"
    continue
  fi

  (
    cd "$build_dir"
    case "$variant" in
      kernelsu)
        CONFIG_KSU=m CC=clang KCFLAGS="$FRAME_WARN_KCFLAGS" make
        ;;
      sukisu)
        CONFIG_KSU=m CONFIG_KSU_TRACEPOINT_HOOK=y CC=clang KCFLAGS="$FRAME_WARN_KCFLAGS" make
        ;;
      resukisu)
        CONFIG_KSU=m CONFIG_KSU_TRACEPOINT_HOOK=y CONFIG_KSU_MULTI_MANAGER_SUPPORT=y CC=clang KCFLAGS="$FRAME_WARN_KCFLAGS" make
        ;;
    esac
  )

  [ -f "$build_dir/kernelsu.ko" ] || die "build did not produce $build_dir/kernelsu.ko"
  cp "$build_dir/kernelsu.ko" "$artifact"
  strip_artifact "$artifact"
  printf '[lkm] built %s\n' "$artifact"
done
