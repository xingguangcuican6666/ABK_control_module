# ABK Control Module

ABK Control Module is an AnyBase Kernel external module that injects a small
kernel-side control framework into the target kernel tree.

It provides:

- A small runtime bridge for reading ABK external module metadata and sending
  simple control commands.
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
stage installs the files again for safety, generates the metadata and build
manifest, and enables `CONFIG_ABK_CONTROL=y`.

## Runtime Status

After booting a kernel built with this module, the runtime bridge returns JSON:

```json
{
  "schema": 3,
  "abk_version": "1.0.6",
  "abk_commit": "abcdef0",
  "manager": {
    "display_name": "ABK Control",
    "variant": "SukiSU",
    "backend": "kernel",
    "version": "",
    "active": true,
    "capabilities": ["build", "modules", "abk_control"]
  },
  "build": {
    "android_version": "android15",
    "kernel_version": "6.6",
    "sub_level": "127",
    "os_patch_level": "2025-01",
    "revision": "",
    "kernelsu_variant": "SukiSU",
    "kernelsu_branch": "Stable(标准)",
    "version": "",
    "build_time": "Wed May 13 14:00:00 CST 2026",
    "virtualization_support": "678",
    "zram_extra_algos": "lz4,zstd",
    "features": {
      "use_zram": true,
      "use_bbg": true,
      "use_ddk": false,
      "use_ntsync": true,
      "use_networking": true,
      "use_kpm": true,
      "use_rekernel": false,
      "enable_susfs": true,
      "supp_op": false,
      "zram_full_algo": false
    }
  },
  "modules": [
    {
      "id": "abk_control",
      "name": "ABK Control Module",
      "version": "0.3.0",
      "description": "Expose ABK external module metadata and a shared kernel control interface.",
      "repo_url": "https://github.com/xingguangcuican6666/ABK_control_module",
      "stage": "after_patch",
      "type": "builtin",
      "source": "abk",
      "readonly": true,
      "controllable": false,
      "enabled": true
    }
  ]
}
```

Supported commands are `status <id>`, `disable <id>`, and `enable <id>`.

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
