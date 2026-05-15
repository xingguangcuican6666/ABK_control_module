# LKM Builds

This directory keeps the standalone LKM build wrapper for the three kernel
upstreams:

- `tiann/KernelSU`
- `SukiSU-Ultra/SukiSU-Ultra`
- `ReSukiSU/ReSukiSU`

It clones them at build time, patches the ABK manager bridge into the cloned
tree, and leaves `setup.sh` untouched.

## Dry run

```sh
bash lkm/build.sh --variant kernelsu --kmi android15-6.6 --dry-run
```

## Build

```sh
bash lkm/build.sh --variant all --kmi android15-6.6
```

Artifacts are written under `lkm/out/` and ignored by git.
