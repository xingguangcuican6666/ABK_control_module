# ABK External Module Template

Template repository for AnyBase Kernel (ABK) custom external modules.

ABK clones external module repositories during the kernel build and runs
`setup.sh` from the repository root at the configured injection stage. This
template is intentionally safe by default: it logs the build context and does
not modify the kernel tree until you add your own logic.

## Usage

Enable "custom external modules" in the ABK app or GitHub Actions, then pass a
module string in this format:

```text
https://github.com/your-name/your-module.git;after_patch
```

For ABK APP

```
https://github.com/your-name/your-module.git
```
Then choose the after_patch.

Multiple modules are separated with `|`:

```text
https://github.com/your-name/module-a.git;after_patch|https://github.com/your-name/module-b.git;before_build
```

Supported stages:

| Stage | Timing | Typical use |
| --- | --- | --- |
| `after_patch` | After ABK finishes built-in source integrations such as SUSFS, ZRAM, BBG, DDK, Re-Kernel, NTsync, IPSet, and BBR | Apply source patches, copy driver files, edit Kconfig or Makefile files |
| `before_build` | After ABK sets the kernel name and build timestamp, immediately before compilation | Final defconfig edits, generated files, validation checks |

`befor_build` is accepted by ABK as a compatibility alias, but new modules
should use `before_build`.

## Repository Layout

```text
.
|-- setup.sh
|-- module.conf
|-- scripts/
|   `-- libabk.sh
|-- patches/
|   `-- README.md
|-- files/
|   `-- README.md
`-- docs/
    `-- development.md
```

Required entry point:

- `setup.sh` must exist at the repository root.
- ABK executes it with `bash setup.sh`.
- The current working directory is the module repository root.

Recommended workflow:

1. Create a new repository from this template.
2. Update `module.conf` with your module name, version, and description.
3. Put patch files under `patches/`.
4. Put source files or templates under `files/`.
5. Implement stage-specific logic in `setup.sh`.
6. Keep every operation idempotent.

## Minimal Example

```bash
#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/scripts/libabk.sh"

abk_require_env KERNEL_ROOT DEFCONFIG CUSTOM_EXTERNAL_MODULE_STAGE

case "$CUSTOM_EXTERNAL_MODULE_STAGE" in
  after_patch)
    abk_apply_patch_dir "$MODULE_DIR/patches/common"
    ;;
  before_build)
    abk_enable_config CONFIG_EXAMPLE_FEATURE
    ;;
esac
```

## Common Environment Variables

| Variable | Meaning |
| --- | --- |
| `GITHUB_WORKSPACE` | GitHub Actions workspace and ABK repository root |
| `CONFIG` | Build tuple, for example `android15-6.6-118` |
| `KERNEL_ROOT` | Kernel source directory |
| `DEFCONFIG` | GKI defconfig path |
| `CUSTOM_EXTERNAL_MODULE_STAGE` | Current stage, `after_patch` or `before_build` |
| `CUSTOM_EXTERNAL_MODULES_MANIFEST` | Parsed ABK module manifest |
| `ZZH_PATCHES` | ABK repository root |
| `SUSFS4KSU` | SUSFS repository path when SUSFS is enabled |
| `KERNEL_PATCHES` | `WildKernels/kernel_patches` repository path |
| `SUKISU_PATCHES` | `ShirkNeko/SukiSU_patch` repository path |
| `ANYKERNEL3` | AnyKernel3 repository path |
| `ACTION_BUILD` | Action-Build repository path |
| `KBUILD_BUILD_TIMESTAMP` | Available in `before_build` |
| `KBUILD_BUILD_VERSION` | Available in `before_build` |

See [docs/development.md](docs/development.md) for the full development guide.

## Safety Rules

- Do not commit tokens, private keys, device private data, or opaque binaries.
- Do not download and execute unaudited remote scripts.
- Validate kernel versions and target files before modifying the source tree.
- Fail clearly with `exit 1` when a required condition is not met.
- Prefer changing only `$KERNEL_ROOT`, `$DEFCONFIG`, or files inside this
  module repository.

## License

GPL-3.0. Make sure any third-party code or patches you add are compatible with
the target kernel and this repository license.
