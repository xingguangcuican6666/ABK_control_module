# Development

ABK clones external module repositories and runs `setup.sh` at each configured
stage. This module supports `after_patch` and `before_build`.

## Stage Behavior

`after_patch`:

- Copies `files/drivers/abk_control` to `common/drivers/abk_control`.
- Copies `files/include/linux/abk_control.h` to `common/include/linux`.
- Appends one Kconfig line and one Makefile line under `common/drivers`.

`before_build`:

- Repeats the source installation so the stage can recover from missing files.
- Reads `CUSTOM_EXTERNAL_MODULES_MANIFEST`.
- Parses each module repository's `module.conf`.
- Generates `common/drivers/abk_control/abk_control_manifest.c`.
- Embeds ABK workflow build parameters from `ABK_BUILD_*` and `ABK_FEATURE_*`
  environment variables.
- Enables `CONFIG_ABK_CONTROL=y` in `$DEFCONFIG`.

All edits are idempotent.

## Metadata

The generator reads these fields from `module.conf`:

| Key | Required | Meaning |
| --- | --- | --- |
| `ABK_MODULE_ID` | No | Stable control id; falls back to sanitized repo name |
| `ABK_MODULE_NAME` | Yes | Display name |
| `ABK_MODULE_VERSION` | No | Display version |
| `ABK_MODULE_DESCRIPTION` | No | Display description |

Invalid or missing metadata is skipped with a warning so one bad module does not
break the whole manifest.

## Build Info

The generated manifest exports schema 2 runtime build information:

- `ABK_BUILD_ANDROID_VERSION`, `ABK_BUILD_KERNEL_VERSION`,
  `ABK_BUILD_SUB_LEVEL`, `ABK_BUILD_OS_PATCH_LEVEL`
- `ABK_BUILD_REVISION`, `ABK_BUILD_KSU_VARIANT`, `ABK_BUILD_KSU_BRANCH`,
  `ABK_BUILD_VERSION`, `ABK_BUILD_TIME`
- `ABK_BUILD_VIRTUALIZATION_SUPPORT`, `ABK_BUILD_ZRAM_EXTRA_ALGOS`
- `ABK_FEATURE_USE_ZRAM`, `ABK_FEATURE_USE_BBG`, `ABK_FEATURE_USE_DDK`,
  `ABK_FEATURE_USE_NTSYNC`, `ABK_FEATURE_USE_NETWORKING`,
  `ABK_FEATURE_USE_KPM`, `ABK_FEATURE_USE_REKERNEL`,
  `ABK_FEATURE_ENABLE_SUSFS`, `ABK_FEATURE_SUPP_OP`,
  `ABK_FEATURE_ZRAM_FULL_ALGO`

The ABK app version is parsed from `$ZZH_PATCHES/app/build.gradle.kts` when
available. The ABK commit is read from the same repository with `git rev-parse`.

## Control API

The copied header defines:

```c
struct abk_control_ops {
	const char *id;
	const char *name;
	const char *version;
	const char *description;
	bool (*is_enabled)(void *data);
	int (*set_enabled)(bool enabled, void *data);
	void *data;
};

int abk_control_register(const struct abk_control_ops *ops);
void abk_control_unregister(const struct abk_control_ops *ops);
```

`id` must be stable and unique. If it matches a generated manifest entry, the
device output upgrades that entry from metadata-only to controllable.

## Tests

Run:

```sh
bash -n setup.sh scripts/libabk.sh scripts/abk_control_setup.sh tests/abk_control_setup_test.sh
bash tests/abk_control_setup_test.sh
```

The test creates a fake kernel tree, fake external modules, runs both stages
twice, and checks file injection, manifest generation, and duplicate prevention.
