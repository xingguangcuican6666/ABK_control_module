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
