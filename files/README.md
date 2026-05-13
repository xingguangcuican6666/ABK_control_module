# files/

Static kernel files copied by `setup.sh`.

```text
files/
|-- drivers/
|   `-- abk_control/
|       |-- Kconfig
|       |-- Makefile
|       `-- core.c
`-- include/
    `-- linux/
        `-- abk_control.h
```

`abk_control_manifest.c` is not stored here. It is generated during the
`before_build` stage from `CUSTOM_EXTERNAL_MODULES_MANIFEST`.
