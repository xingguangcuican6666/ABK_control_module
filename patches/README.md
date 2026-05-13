# patches/

Place `git format-patch` or `git diff` patches here.

Recommended layout:

```text
patches/
|-- common/
|   `-- 0001-example.patch
|-- 5.10/
|   `-- 0001-example-5.10.patch
`-- 6.x/
    `-- 0001-example-6.x.patch
```

Example usage in `setup.sh`:

```bash
abk_apply_patch_dir "$MODULE_DIR/patches/common"
```
