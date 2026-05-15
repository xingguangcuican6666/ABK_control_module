# LKM Builds

This directory keeps the standalone LKM build wrapper for the three kernel
submodules:

- `external/KernelSU`
- `external/SukiSU-Ultra`
- `external/ReSukiSU`

It does not touch `setup.sh` or the ABK module install flow.

## Dry run

```sh
bash lkm/build.sh --variant kernelsu --kmi android15-6.6 --dry-run
```

## Build

```sh
bash lkm/build.sh --variant all --kmi android15-6.6
```

Artifacts are written under `lkm/out/` and ignored by git.
