# ABK Control Module

ABK Control Module is an AnyBase Kernel external module that injects a small
kernel-side control framework into the target kernel tree.

It provides:

- `/dev/abk_control`, a misc character device for reading ABK external module
  metadata and sending simple control commands.
- `include/linux/abk_control.h`, a shared in-kernel API that future controllable
  ABK modules can use to register enable/disable callbacks.
- Build-time metadata collection from ABK custom external module `module.conf`
  files.

## Usage

Add this repository as a custom external module and select both stages:

```text
https://github.com/xingguangcuican6666/ABK_control_module.git;after_patch|https://github.com/xingguangcuican6666/ABK_control_module.git;before_build
```

The `after_patch` stage installs the kernel source files. The `before_build`
stage installs the files again for safety, generates the metadata manifest, and
enables `CONFIG_ABK_CONTROL=y`.

## Device Interface

After booting a kernel built with this module, read:

```sh
cat /dev/abk_control
```

The device returns JSON:

```json
{
  "schema": 1,
  "modules": [
    {
      "id": "abk_control",
      "name": "ABK Control Module",
      "version": "0.1.0",
      "description": "Expose ABK external module metadata and a shared kernel control interface through /dev/abk_control.",
      "repo_url": "https://github.com/xingguangcuican6666/ABK_control_module",
      "stage": "after_patch",
      "controllable": false,
      "enabled": true
    }
  ]
}
```

Supported write commands:

```sh
printf 'status abk_control\n' > /dev/abk_control
printf 'disable some_feature\n' > /dev/abk_control
printf 'enable some_feature\n' > /dev/abk_control
```

Modules that only appear in the build-time manifest are metadata-only. Enable
and disable commands return `-EOPNOTSUPP` until a kernel component registers a
matching control callback.

## Kernel API

Controllable kernel code should include:

```c
#include <linux/abk_control.h>
```

Register an operation table:

```c
static bool my_feature_enabled(void *data)
{
	return true;
}

static int my_feature_set_enabled(bool enabled, void *data)
{
	return 0;
}

static const struct abk_control_ops my_feature_ops = {
	.id = "my_feature",
	.name = "My Feature",
	.version = "1.0",
	.description = "Example controllable feature",
	.is_enabled = my_feature_enabled,
	.set_enabled = my_feature_set_enabled,
};

abk_control_register(&my_feature_ops);
```

Use `abk_control_unregister(&my_feature_ops)` when removing a dynamically
loaded component.

## Development

Run local checks:

```sh
bash -n setup.sh scripts/libabk.sh scripts/abk_control_setup.sh tests/abk_control_setup_test.sh
bash tests/abk_control_setup_test.sh
```

Full kernel compilation is expected to run in ABK GitHub Actions.
