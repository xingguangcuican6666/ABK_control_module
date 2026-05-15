#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_OUT_DIR="$ROOT_DIR/lkm/out"

usage() {
  cat <<'EOF'
usage: lkm/build.sh [--variant NAME|all] [--kmi KMI] [--out-dir PATH] [--dry-run] [--list]

variants:
  kernelsu
  sukisu
  resukisu
EOF
}

die() {
  printf '[lkm] %s\n' "$*" >&2
  exit 1
}

variant_dir() {
  case "$1" in
    kernelsu) printf '%s/external/KernelSU/kernel\n' "$ROOT_DIR" ;;
    sukisu) printf '%s/external/SukiSU-Ultra/kernel\n' "$ROOT_DIR" ;;
    resukisu) printf '%s/external/ReSukiSU/kernel\n' "$ROOT_DIR" ;;
    *) return 1 ;;
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

VARIANT="${LKM_VARIANT:-all}"
KMI="${LKM_KMI:-${DDK_TARGET:-}}"
OUT_DIR="${LKM_OUT_DIR:-$DEFAULT_OUT_DIR}"
DRY_RUN=0

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
  source_dir="$(variant_dir "$variant")" || die "unsupported variant: $variant"
  artifact_dir="$OUT_DIR/$variant"
  artifact="$artifact_dir/${KMI}_kernelsu.ko"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\t%s\t%s\n' "$variant" "$source_dir" "$artifact"
    continue
  fi

  [ -d "$source_dir" ] || die "missing source directory: $source_dir"
  mkdir -p "$artifact_dir"

  (
    cd "$source_dir"
    case "$variant" in
      kernelsu)
        CONFIG_KSU=m CC=clang make
        ;;
      sukisu)
        CONFIG_KSU=m CONFIG_KSU_TRACEPOINT_HOOK=y CC=clang make
        ;;
      resukisu)
        CONFIG_KSU=m CONFIG_KSU_TRACEPOINT_HOOK=y CONFIG_KSU_MULTI_MANAGER_SUPPORT=y CC=clang make
        ;;
    esac
  )

  [ -f "$source_dir/kernelsu.ko" ] || die "build did not produce $source_dir/kernelsu.ko"
  cp "$source_dir/kernelsu.ko" "$artifact"
  strip_artifact "$artifact"
  printf '[lkm] built %s\n' "$artifact"
done
