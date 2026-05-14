#!/usr/bin/env python3
import os
import re
from pathlib import Path


DEFAULT_MANAGER_PACKAGE = "com.abk.kernel"
DEFAULT_MANAGER_CERT_SIZE = "1407"
DEFAULT_MANAGER_CERT_SHA256 = "34e5e843952277759603cd0f949770b24c868530d80d7baeff08776a7e132b16"
DEFAULT_MANAGER_CERT_MAX_LENGTH = "2048"


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def write_if_changed(path: Path, text: str) -> bool:
    old = path.read_text(errors="ignore")
    if old == text:
        return False
    path.write_text(text)
    return True


def module_dir() -> Path:
    return Path(os.environ.get("MODULE_DIR", Path(__file__).resolve().parents[1])).resolve()


def kernel_root() -> Path:
    root = os.environ.get("KERNEL_ROOT")
    if not root:
        raise SystemExit("KERNEL_ROOT is required")
    return Path(root).resolve()


def manager_cert_max_length(cert_size: str) -> str:
    size = int(cert_size, 0)
    if size <= 0 or size > 8192:
        raise SystemExit("ABK manager certificate size is outside supported range")
    for candidate in (1024, 2048, 4096, 8192):
        if size <= candidate:
            return str(max(candidate, int(DEFAULT_MANAGER_CERT_MAX_LENGTH)))
    return "8192"


def manager_identity() -> tuple[str, str, str, str]:
    conf = read_env_file(module_dir() / "module.conf")
    package = (
        os.environ.get("ABK_MANAGER_PACKAGE")
        or conf.get("ABK_MANAGER_PACKAGE")
        or DEFAULT_MANAGER_PACKAGE
    )
    cert_size = (
        os.environ.get("ABK_MANAGER_CERT_SIZE")
        or conf.get("ABK_MANAGER_CERT_SIZE")
        or DEFAULT_MANAGER_CERT_SIZE
    )
    cert_hash = (
        os.environ.get("ABK_MANAGER_CERT_SHA256")
        or conf.get("ABK_MANAGER_CERT_SHA256")
        or DEFAULT_MANAGER_CERT_SHA256
    ).lower()

    if not re.fullmatch(r"[A-Za-z0-9_.]+", package):
        raise SystemExit(f"ABK manager package is invalid: {package}")
    if not re.fullmatch(r"(0x[0-9a-fA-F]+|[0-9]+)", cert_size):
        raise SystemExit("ABK manager certificate size is invalid")
    if not re.fullmatch(r"[0-9a-f]{64}", cert_hash):
        raise SystemExit("ABK manager certificate SHA-256 is invalid")
    cert_max_length = manager_cert_max_length(cert_size)
    return package, cert_size, cert_hash, cert_max_length


def find_ksu_dirs(root: Path) -> list[Path]:
    dirs: list[Path] = []
    seen: set[Path] = set()

    preferred = [
        root / "common/drivers/kernelsu",
        root / "drivers/kernelsu",
        root / "KernelSU/kernel",
        root / "kernel",
    ]
    for candidate in preferred:
        if (candidate / "Kbuild").exists() and (candidate / "manager/apk_sign.c").exists():
            resolved = candidate.resolve()
            if resolved not in seen:
                seen.add(resolved)
                dirs.append(candidate)

    for dispatch in root.rglob("supercall/dispatch.c"):
        candidate = dispatch.parent.parent
        if not (candidate / "Kbuild").exists():
            continue
        if not (candidate / "manager/apk_sign.c").exists():
            continue
        resolved = candidate.resolve()
        if resolved not in seen:
            seen.add(resolved)
            dirs.append(candidate)

    return dirs


def ensure_kbuild_macros(ksu_dir: Path, package: str, cert_size: str, cert_hash: str, cert_max_length: str) -> None:
    path = ksu_dir / "Kbuild"
    text = path.read_text(errors="ignore")
    filtered_lines = []
    for line in text.splitlines():
        if "ABK Control: trust the official ABK manager release certificate." in line:
            continue
        if re.search(r"\bABK_MANAGER_(PACKAGE|CERT_SIZE|CERT_SHA256|CERT_MAX_LENGTH|OFFICIAL_CERT)\b", line):
            continue
        filtered_lines.append(line)
    block = "\n".join([
        "",
        "# ABK Control: trust the official ABK manager release certificate.",
        f"ccflags-y += -DABK_MANAGER_PACKAGE=\\\"{package}\\\"",
        f"ccflags-y += -DABK_MANAGER_CERT_SIZE={cert_size}",
        f"ccflags-y += -DABK_MANAGER_CERT_SHA256=\\\"{cert_hash}\\\"",
        f"ccflags-y += -DABK_MANAGER_CERT_MAX_LENGTH={cert_max_length}",
        "ccflags-y += -DABK_MANAGER_OFFICIAL_CERT=1",
        "",
    ])
    new_text = "\n".join(filtered_lines).rstrip() + "\n" + block
    if write_if_changed(path, new_text):
        print(f"ABK Control: configured manager identity macros in {path}")


CERT_MAX_PATTERN = re.compile(
    r"(?P<indent>[ \t]*)#[ \t]*define[ \t]+CERT_MAX_LENGTH[ \t]+(?P<value>0x[0-9a-fA-F]+|[0-9]+)"
)


def patch_cert_max_length(text: str, path: Path) -> tuple[str, bool]:
    if "ABK_MANAGER_CERT_MAX_LENGTH" in text:
        return text, False

    def replacement(match: re.Match[str]) -> str:
        indent = match.group("indent")
        value = match.group("value")
        return "\n".join([
            f"{indent}#ifdef ABK_MANAGER_OFFICIAL_CERT",
            f"{indent}#define CERT_MAX_LENGTH ABK_MANAGER_CERT_MAX_LENGTH",
            f"{indent}#else",
            f"{indent}#define CERT_MAX_LENGTH {value}",
            f"{indent}#endif",
        ])

    text, count = CERT_MAX_PATTERN.subn(replacement, text, count=1)
    if count:
        return text, True
    if "CERT_MAX_LENGTH" in text:
        raise SystemExit(f"{path} contains CERT_MAX_LENGTH but no supported define")
    return text, False


PACKAGE_GATE_PATTERN = re.compile(
    r"(?P<indent>[ \t]*)if \(strncmp\(pkg, KSU_MANAGER_PACKAGE, sizeof\(KSU_MANAGER_PACKAGE\)\)\) \{\n"
    r"(?P=indent)[ \t]+return false;\n"
    r"(?P=indent)\}"
)


def package_gate_replacement(match: re.Match[str]) -> str:
    indent = match.group("indent")
    inner = indent + "    "
    return (
        f"{indent}if (strncmp(pkg, KSU_MANAGER_PACKAGE, sizeof(KSU_MANAGER_PACKAGE))) {{\n"
        "#ifdef ABK_MANAGER_OFFICIAL_CERT\n"
        f"{inner}if (strncmp(pkg, ABK_MANAGER_PACKAGE, sizeof(ABK_MANAGER_PACKAGE))) {{\n"
        f"{inner}    return false;\n"
        f"{inner}}}\n"
        "#else\n"
        f"{inner}return false;\n"
        "#endif\n"
        f"{indent}}}"
    )


def patch_apk_sign(ksu_dir: Path) -> None:
    path = ksu_dir / "manager/apk_sign.c"
    text = path.read_text(errors="ignore")
    if "bool is_manager_apk" not in text:
        raise SystemExit(f"{path} does not contain is_manager_apk")

    changed = False
    text, cert_max_changed = patch_cert_max_length(text, path)
    changed = changed or cert_max_changed

    if "ABK_MANAGER_PACKAGE" not in text:
        text, count = PACKAGE_GATE_PATTERN.subn(package_gate_replacement, text, count=1)
        changed = changed or bool(count)

    if "ABK_MANAGER_CERT_SHA256" not in text:
        if "static apk_sign_key_t apk_sign_keys[] = {" in text:
            snippet = """#ifdef ABK_MANAGER_OFFICIAL_CERT
    { ABK_MANAGER_CERT_SIZE, ABK_MANAGER_CERT_SHA256 }, /* ABK official manager */
#endif
"""
            start = text.find("static apk_sign_key_t apk_sign_keys[] = {")
            end = text.find("};", start)
            if end < 0:
                raise SystemExit(f"{path} missing apk_sign_keys end marker")
            text = text[:end] + snippet + text[end:]
            changed = True
        else:
            anchor = """    if (check_v2_signature(path, EXPECTED_SIZE, EXPECTED_HASH)) {
        return true;
    }
"""
            snippet = """#ifdef ABK_MANAGER_OFFICIAL_CERT
    if (check_v2_signature(path, ABK_MANAGER_CERT_SIZE, ABK_MANAGER_CERT_SHA256)) {
        return true;
    }
#endif
"""
            if anchor not in text:
                raise SystemExit(f"{path} missing direct signature check anchor")
            text = text.replace(anchor, anchor + snippet, 1)
            changed = True

    if write_if_changed(path, text) or changed:
        print(f"ABK Control: patched manager APK signature recognition in {path}")


def patch_throne_header(ksu_dir: Path) -> None:
    path = ksu_dir / "manager/throne_tracker.h"
    if not path.exists():
        raise SystemExit(f"{path} is missing")
    text = path.read_text(errors="ignore")
    if "abk_try_register_manager" in text:
        return
    insert = """
#ifdef ABK_MANAGER_OFFICIAL_CERT
#ifdef CONFIG_KSU_DISABLE_MANAGER
static inline void abk_try_register_manager(void)
{
}
#else
void abk_try_register_manager(void);
#endif
#endif
"""
    marker = "\n#endif\n"
    if marker not in text:
        raise SystemExit(f"{path} missing final header guard")
    path.write_text(text.rsplit(marker, 1)[0] + insert + marker)
    print(f"ABK Control: declared manager registration hook in {path}")


def patch_resukisu_tracker(path: Path) -> None:
    text = path.read_text(errors="ignore")
    if "void abk_try_register_manager(void)" in text:
        return
    anchor = "\nvoid track_throne(unsigned int flags)\n"
    if anchor not in text:
        raise SystemExit(f"{path} missing ReSukiSU track_throne anchor")
    block = """
#ifdef ABK_MANAGER_OFFICIAL_CERT
void abk_try_register_manager(void)
{
    struct track_throne_struct *tts;

    if (is_manager())
        return;

    tts = kzalloc(sizeof(*tts), GFP_KERNEL);
    if (!tts)
        return;

    tts->flags = TRACK_THRONE_FORCE_SEARCH_MGR;
    do_track_throne(tts);
}
#endif
"""
    path.write_text(text.replace(anchor, block + anchor, 1))
    print(f"ABK Control: patched ReSukiSU manager registration in {path}")


def patch_single_manager_tracker(path: Path) -> None:
    text = path.read_text(errors="ignore")
    changed = False

    if "ABK Control: prefer ABK manager" not in text:
        anchor = '    pr_info("manager pkg: %s\\n", pkg);\n'
        if anchor not in text:
            raise SystemExit(f"{path} missing crown_manager log anchor")
        block = """
#ifdef ABK_MANAGER_OFFICIAL_CERT
    /* ABK Control: prefer ABK manager when its release signature is trusted. */
    if (strncmp(pkg, ABK_MANAGER_PACKAGE, sizeof(ABK_MANAGER_PACKAGE)) != 0 &&
        ksu_is_manager_appid_valid())
        return;
#endif
"""
        text = text.replace(anchor, anchor + block, 1)
        changed = True

    if "bool should_stop = get_pkg_from_apk_path" not in text:
        stop_pattern = re.compile(
            r"(?P<indent>[ \t]*)if \(is_manager\) \{\n"
            r"(?P=indent)[ \t]+crown_manager\(dirpath, my_ctx->private_data\);\n"
            r"(?P=indent)[ \t]+\*my_ctx->stop = 1;\n\n"
            r"(?P=indent)[ \t]+// Manager found, clear APK cache list\n"
            r"(?P=indent)[ \t]+list_for_each_entry_safe \(pos, n, &apk_path_hash_list, list\) \{\n"
            r"(?P=indent)[ \t]+[ \t]+list_del\(&pos->list\);\n"
            r"(?P=indent)[ \t]+[ \t]+kfree\(pos\);\n"
            r"(?P=indent)[ \t]+\}\n"
            r"(?P=indent)\} else \{"
        )

        def stop_replacement(match: re.Match[str]) -> str:
            indent = match.group("indent")
            inner = indent + "    "
            return "\n".join([
                f"{indent}if (is_manager) {{",
                "#ifdef ABK_MANAGER_OFFICIAL_CERT",
                f"{inner}char pkg[KSU_MAX_PACKAGE_NAME];",
                f"{inner}bool should_stop = get_pkg_from_apk_path(pkg, dirpath) == 0 &&",
                f"{inner}                   strncmp(pkg, ABK_MANAGER_PACKAGE, sizeof(ABK_MANAGER_PACKAGE)) == 0;",
                "#else",
                f"{inner}bool should_stop = true;",
                "#endif",
                f"{inner}crown_manager(dirpath, my_ctx->private_data);",
                f"{inner}if (should_stop) {{",
                f"{inner}    *my_ctx->stop = 1;",
                "",
                f"{inner}    // Manager found, clear APK cache list",
                f"{inner}    list_for_each_entry_safe (pos, n, &apk_path_hash_list, list) {{",
                f"{inner}        list_del(&pos->list);",
                f"{inner}        kfree(pos);",
                f"{inner}    }}",
                f"{inner}}}",
                f"{indent}}} else {{",
            ])

        text, count = stop_pattern.subn(stop_replacement, text, count=1)
        if not count:
            raise SystemExit(f"{path} missing single-manager stop anchor")
        changed = True

    if "void abk_try_register_manager(void)" not in text:
        anchor = "\nvoid __init ksu_throne_tracker_init()"
        if anchor not in text:
            raise SystemExit(f"{path} missing ksu_throne_tracker_init anchor")
        block = """
#ifdef ABK_MANAGER_OFFICIAL_CERT
void abk_try_register_manager(void)
{
    struct file *fp;

    if (is_manager())
        return;

    fp = filp_open(SYSTEM_PACKAGES_LIST_PATH, O_RDONLY, 0);
    if (IS_ERR(fp))
        return;
    filp_close(fp, 0);

    ksu_invalidate_manager_uid();
    track_throne(false);
}
#endif
"""
        text = text.replace(anchor, block + anchor, 1)
        changed = True

    if changed:
        path.write_text(text)
        print(f"ABK Control: patched single-manager registration in {path}")


def patch_tracker(ksu_dir: Path) -> None:
    path = ksu_dir / "manager/throne_tracker.c"
    if not path.exists():
        raise SystemExit(f"{path} is missing")
    text = path.read_text(errors="ignore")
    header = (ksu_dir / "manager/throne_tracker.h").read_text(errors="ignore")
    if (
        "do_track_throne" in text
        and "track_throne(unsigned int flags)" in header
        and "TRACK_THRONE_FORCE_SEARCH_MGR" in header
    ):
        patch_resukisu_tracker(path)
    else:
        patch_single_manager_tracker(path)


def patch_dispatch_registration(ksu_dir: Path) -> None:
    path = ksu_dir / "supercall/dispatch.c"
    if not path.exists():
        raise SystemExit(f"{path} is missing")
    text = path.read_text(errors="ignore")
    if '"manager/throne_tracker.h"' not in text:
        anchor = '#include "manager/manager_identity.h"\n'
        if anchor not in text:
            raise SystemExit(f"{path} missing manager_identity include anchor")
        text = text.replace(anchor, anchor + '#include "manager/throne_tracker.h"\n', 1)
    block = """#ifdef ABK_MANAGER_OFFICIAL_CERT
    if (!is_manager()) {
        abk_try_register_manager();
    }
#endif
"""
    if "abk_try_register_manager();" not in text:
        anchor = """    if (is_manager()) {
        cmd.flags |= KSU_GET_INFO_FLAG_MANAGER;
    }
"""
        if anchor not in text:
            raise SystemExit(f"{path} missing GET_INFO manager flag anchor")
        text = text.replace(anchor, block + anchor, 1)
    if write_if_changed(path, text):
        print(f"ABK Control: connected manager registration to GET_INFO in {path}")


def patch_control_bridge(ksu_dir: Path) -> None:
    path = ksu_dir / "supercall/dispatch.c"
    text = path.read_text(errors="ignore")
    marker = "ABK_CONTROL_SUPERCALL_BRIDGE"
    if marker in text:
        return
    if "ksu_ioctl_handlers" not in text or "ksu_supercall_handle_ioctl" not in text:
        raise SystemExit(f"{path} is not a recognized KernelSU supercall dispatch")

    include_snippet = """#ifdef CONFIG_ABK_CONTROL
#include <linux/abk_control.h>
#endif
"""
    if "<linux/abk_control.h>" not in text:
        if "#include <linux/version.h>\n" in text:
            text = text.replace("#include <linux/version.h>\n", "#include <linux/version.h>\n" + include_snippet, 1)
        elif "#include <linux/uaccess.h>\n" in text:
            text = text.replace("#include <linux/uaccess.h>\n", "#include <linux/uaccess.h>\n" + include_snippet, 1)
        else:
            raise SystemExit(f"{path} missing include injection anchor")

    handler_snippet = """
#ifdef CONFIG_ABK_CONTROL
/* ABK_CONTROL_SUPERCALL_BRIDGE */
static int do_abk_control_get_status(void __user *arg)
{
    struct abk_control_status_cmd cmd;
    char *json = NULL;
    size_t json_len = 0;
    u64 user_data;
    u64 user_len;
    int ret;

    if (copy_from_user(&cmd, arg, sizeof(cmd)))
        return -EFAULT;

    user_data = cmd.data;
    user_len = cmd.data_len;

    ret = abk_control_get_status_json(&json, &json_len);
    if (ret)
        return ret;

    cmd.data_len = json_len;
    if (!user_data || user_len < json_len) {
        ret = -ENOSPC;
        goto out;
    }

    if (json_len && copy_to_user((void __user *)(unsigned long)user_data, json, json_len)) {
        ret = -EFAULT;
        goto out_free;
    }

    ret = 0;
out:
    if (copy_to_user(arg, &cmd, sizeof(cmd)))
        ret = -EFAULT;
out_free:
    kfree(json);
    return ret;
}

static int do_abk_control_run_command(void __user *arg)
{
    struct abk_control_command_cmd cmd;
    char command[ABK_CONTROL_MAX_COMMAND];

    if (copy_from_user(&cmd, arg, sizeof(cmd)))
        return -EFAULT;
    if (!cmd.command || cmd.command_len == 0 || cmd.command_len > ABK_CONTROL_MAX_COMMAND)
        return -EINVAL;
    if (copy_from_user(command, (void __user *)(unsigned long)cmd.command, cmd.command_len))
        return -EFAULT;

    return abk_control_run_command(command, cmd.command_len);
}
#endif

"""
    handler_anchor = "// IOCTL handlers mapping table"
    if handler_anchor not in text:
        raise SystemExit(f"{path} missing IOCTL handler table anchor")
    text = text.replace(handler_anchor, handler_snippet + handler_anchor, 1)

    entry_snippet = """#ifdef CONFIG_ABK_CONTROL
    {
        .cmd = ABK_CONTROL_IOCTL_GET_STATUS,
        .name = "ABK_CONTROL_GET_STATUS",
        .handler = do_abk_control_get_status,
        .perm_check = manager_or_root
    },
    {
        .cmd = ABK_CONTROL_IOCTL_RUN_COMMAND,
        .name = "ABK_CONTROL_RUN_COMMAND",
        .handler = do_abk_control_run_command,
        .perm_check = manager_or_root
    },
#endif
"""
    sentinel = re.search(r"\n\s*\{\s*\n\s*\.cmd\s*=\s*0\s*,", text)
    if not sentinel:
        raise SystemExit(f"{path} missing IOCTL handler sentinel")
    text = text[:sentinel.start() + 1] + entry_snippet + text[sentinel.start() + 1:]
    path.write_text(text)
    print(f"ABK Control: injected supercall bridge in {path}")


def validate_ksu_dir(ksu_dir: Path, require_control_bridge: bool) -> None:
    required = {
        ksu_dir / "Kbuild": [
            "ABK_MANAGER_PACKAGE",
            "ABK_MANAGER_CERT_SHA256",
            "ABK_MANAGER_CERT_MAX_LENGTH",
            "ABK_MANAGER_OFFICIAL_CERT",
        ],
        ksu_dir / "manager/apk_sign.c": ["ABK_MANAGER_CERT_SHA256", "ABK_MANAGER_CERT_MAX_LENGTH"],
        ksu_dir / "manager/throne_tracker.h": ["abk_try_register_manager"],
        ksu_dir / "manager/throne_tracker.c": ["abk_try_register_manager"],
        ksu_dir / "supercall/dispatch.c": ["abk_try_register_manager", "KSU_GET_INFO_FLAG_MANAGER"],
    }
    if require_control_bridge:
        required[ksu_dir / "supercall/dispatch.c"].append("ABK_CONTROL_IOCTL_GET_STATUS")

    for path, needles in required.items():
        text = path.read_text(errors="ignore")
        missing = [needle for needle in needles if needle not in text]
        if missing:
            raise SystemExit(f"{path} missing ABK Control injection: {', '.join(missing)}")


def main() -> None:
    root = kernel_root()
    package, cert_size, cert_hash, cert_max_length = manager_identity()
    ksu_dirs = find_ksu_dirs(root)
    if not ksu_dirs:
        print("ABK Control: no KernelSU source directory found, skip manager bridge")
        return

    control_header_exists = any(root.rglob("include/linux/abk_control.h"))
    print(f"ABK Control: manager package {package}")
    print(f"ABK Control: manager cert size {cert_size}")
    print(f"ABK Control: manager cert sha256 {cert_hash}")
    print(f"ABK Control: manager cert max length {cert_max_length}")
    for ksu_dir in ksu_dirs:
        print(f"ABK Control: patching KSU source {ksu_dir}")
        ensure_kbuild_macros(ksu_dir, package, cert_size, cert_hash, cert_max_length)
        patch_apk_sign(ksu_dir)
        patch_throne_header(ksu_dir)
        patch_tracker(ksu_dir)
        patch_dispatch_registration(ksu_dir)
        if control_header_exists:
            patch_control_bridge(ksu_dir)
        validate_ksu_dir(ksu_dir, control_header_exists)

    print("ABK Control: KernelSU manager/control bridge ready")


if __name__ == "__main__":
    main()
