# files/

Place source files, Kconfig files, Makefile snippets, or generated templates
that should be copied into `$KERNEL_ROOT`.

Example layout:

```text
files/
`-- drivers/
    `-- example/
        |-- Kconfig
        |-- Makefile
        `-- example.c
```

Example usage in `setup.sh`:

```bash
abk_copy_into_kernel "$MODULE_DIR/files/drivers/example" "common/drivers/example"
```
