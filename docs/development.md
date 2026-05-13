# ABK External Module Development

An ABK external module is a normal Git repository. During a build, ABK clones
the repository and runs `setup.sh` at the configured stage.

## Input Format

```text
repo_url;stage|repo_url;stage
```

Example:

```text
https://github.com/your-name/net-patch.git;after_patch|https://github.com/your-name/final-config.git;before_build
```

Rules:

- `repo_url` supports `https://`, `http://`, `git://`, `ssh://`, and `git@`.
- `stage` supports `after_patch` and `before_build`.
- Every module repository must provide `setup.sh` at the repository root.
- ABK runs the entry point with `bash setup.sh`.

## Stage Selection

### after_patch

Use this stage for source integration:

- Apply `git apply` patches.
- Copy drivers, Kconfig files, Makefiles, or headers.
- Add compatibility fixes after ABK built-in patches.

At this point the kernel source tree exists and ABK built-in patches have mostly
finished, but final kernel name and build-time settings may not be written yet.

### before_build

Use this stage for final configuration:

- Edit `$DEFCONFIG`.
- Read `KBUILD_BUILD_TIMESTAMP` or `KBUILD_BUILD_VERSION`.
- Validate the source tree and configuration immediately before compilation.

## Environment Variables

| Variable | Meaning |
| --- | --- |
| `GITHUB_WORKSPACE` | GitHub Actions workspace and ABK repository root |
| `CONFIG` | Build tuple such as `android15-6.6-118` |
| `KERNEL_ROOT` | Kernel source directory |
| `DEFCONFIG` | GKI defconfig path |
| `ZZH_PATCHES` | ABK repository root |
| `SUSFS4KSU` | Expected SUSFS repository path |
| `KERNEL_PATCHES` | `WildKernels/kernel_patches` clone path |
| `SUKISU_PATCHES` | `ShirkNeko/SukiSU_patch` clone path |
| `ANYKERNEL3` | AnyKernel3 clone path |
| `ACTION_BUILD` | Action-Build clone path |
| `CUSTOM_EXTERNAL_MODULES_MANIFEST` | Parsed custom-module manifest TSV file |
| `CUSTOM_EXTERNAL_MODULE_STAGE` | Current stage |
| `REPO` | Android `repo` tool path |
| `REMOTE_BRANCH` | Queried `kernel/common` target branch |
| `ACTUAL_SUBLEVEL` | Actual sublevel read from the kernel `Makefile` |
| `BRANCH` | KernelSU setup branch argument |
| `KSU_LATEST_COMMIT_DATE` | Latest KernelSU commit date |
| `SUSFS_LATEST_COMMIT_DATE` | Latest SUSFS commit date, or `disabled`/localized value when disabled |
| `AVBTOOL` / `MKBOOTIMG` / `UNPACK_BOOTIMG` / `BOOT_SIGN_KEY_PATH` | Packaging and signing tools |
| `CCACHE_DIR` | ccache directory |

Conditional variables:

- `KSU_VERSION`: set for KernelSU Official builds.
- `KBUILD_BUILD_TIMESTAMP` and `KBUILD_BUILD_VERSION`: guaranteed only in
  `before_build`.
- Standard GitHub Actions variables such as `GITHUB_REPOSITORY`, `GITHUB_REF`,
  `GITHUB_SHA`, `GITHUB_RUN_ID`, `RUNNER_OS`, `RUNNER_TEMP`, `HOME`, and `PATH`
  are also available.

## Helper Functions

`setup.sh` loads `scripts/libabk.sh`.

| Function | Purpose |
| --- | --- |
| `abk_log "msg"` | Print a normal log line |
| `abk_warn "msg"` | Print a warning |
| `abk_die "msg"` | Print an error and exit |
| `abk_require_env VAR...` | Require environment variables |
| `abk_common_dir` | Print `$KERNEL_ROOT/common` |
| `abk_kernel_version` | Print `major.minor.sublevel` from `common/Makefile` |
| `abk_stage_is after_patch` | Test the current stage |
| `abk_enable_config CONFIG_FOO` | Idempotently set a defconfig symbol to `y` |
| `abk_module_config CONFIG_FOO` | Idempotently set a defconfig symbol to `m` |
| `abk_disable_config CONFIG_FOO` | Idempotently disable a defconfig symbol |
| `abk_append_line_once file line` | Append one line only if missing |
| `abk_apply_patch file.patch [target_dir]` | Idempotently apply one patch |
| `abk_apply_patch_dir patches/dir [target_dir]` | Apply all `*.patch` files in lexical order |
| `abk_copy_into_kernel source relative_target` | Copy a file or directory under `$KERNEL_ROOT` |

## Common Patterns

Apply patches by kernel version:

```bash
kernel_version="$(abk_kernel_version)"
case "$kernel_version" in
  5.10.*)
    abk_apply_patch_dir "$MODULE_DIR/patches/5.10"
    ;;
  5.15.*)
    abk_apply_patch_dir "$MODULE_DIR/patches/5.15"
    ;;
  6.1.*|6.6.*|6.12.*)
    abk_apply_patch_dir "$MODULE_DIR/patches/6.x"
    ;;
  *)
    abk_die "unsupported kernel version: $kernel_version"
    ;;
esac
```

Edit defconfig only in `before_build`:

```bash
if abk_stage_is before_build; then
  abk_enable_config CONFIG_EXAMPLE_FEATURE
fi
```

Copy source files:

```bash
if abk_stage_is after_patch; then
  abk_copy_into_kernel "$MODULE_DIR/files/example_driver" "common/drivers/example_driver"
fi
```

## Pre-commit Checks

At minimum, run:

```bash
bash -n setup.sh scripts/libabk.sh
```

If your module includes patches, check the ABK build log and confirm:

- Patches apply cleanly.
- Re-running the module does not duplicate changes.
- Unsupported kernel versions fail clearly.
- Kconfig symbols exist before adding strict defconfig expectations.

## Compatibility Advice

- Do not assume one fixed kernel sublevel. Read `CONFIG` or use
  `abk_kernel_version`.
- Handle Android 12/13 5.x and Android 14+ Bazel/Kleaf differences explicitly.
- Do not hardcode paths such as `$GITHUB_WORKSPACE/android15-6.6-118`; use
  `$KERNEL_ROOT`.
- Pin external dependencies to tags or commits when reproducibility matters.
