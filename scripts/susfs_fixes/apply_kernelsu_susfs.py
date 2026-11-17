#!/usr/bin/env python3
"""Add SUSFS support to native KernelSU (tiann/KernelSU).

The tiann/KernelSU structure may change between commits:
- kernel/core/init.c: contains the kernelsu_init() function
- kernel/Kconfig: menu definitions
- kernel/Kbuild: compilation units

The simonpunk/susfs4ksu patch targets flat kernel/ksu.c and does not match the tiann/KernelSU structure,
so modify the source directly. If automatic integration fails, return a nonzero exit code so the caller can fall back to manual sed edits.
"""

import sys
from pathlib import Path

KSU_KERNEL = Path("KernelSU/kernel")


def modify_kconfig():
    """Add the complete KSU_SUSFS menu to Kconfig."""
    kconfig = KSU_KERNEL / "Kconfig"
    if not kconfig.exists():
        print(f"WARNING: {kconfig} not found, skipping SUSFS menu for KernelSU", file=sys.stderr)
        return False
    s = kconfig.read_text(encoding="utf-8")
    if "config KSU_SUSFS" in s:
        print("Kconfig: SUSFS menu already present")
        return True
    marker = "endmenu\n"
    insertion = (
        'menu "KernelSU - SUSFS"\n'
        'config KSU_SUSFS\n'
        '\tbool "KernelSU addon - SUSFS"\n'
        '\tdepends on KSU\n'
        '\tdefault y\n'
        '\thelp\n'
        '\t  Patch and Enable SUSFS to kernel with KernelSU\n'
        '\n'
        'config KSU_SUSFS_SUS_PATH\n'
        '\tbool "Enable to hide suspicious path"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_SUS_MOUNT\n'
        '\tbool "Enable to hide suspicious mounts"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_SUS_KSTAT\n'
        '\tbool "Enable to spoof suspicious kstat"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_SPOOF_UNAME\n'
        '\tbool "Enable to spoof uname"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_ENABLE_LOG\n'
        '\tbool "Enable logging susfs log to kernel"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS\n'
        '\tbool "Hide KSU SUSFS symbols"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n'
        '\tbool "Spoof cmdline or bootconfig"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_SUS_MAP\n'
        '\tbool "Enable SUS_MAP"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_OPEN_REDIRECT\n'
        '\tbool "Enable open redirect"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        '\n'
        'config KSU_SUSFS_PRIORITY_UID_FILTER\n'
        '\tbool "Enable priority UID filter"\n'
        '\tdepends on KSU_SUSFS\n'
        '\tdefault y\n'
        'endmenu\n'
    )
    idx = s.find(marker)
    if idx < 0:
        # Try other endmenu variants
        for m in ("endmenu\r\n", "endmenu"):
            idx = s.find(m)
            if idx >= 0:
                break
        if idx < 0:
            print("WARNING: endmenu not found in Kconfig, skipping SUSFS menu", file=sys.stderr)
            return False
    s = s[:idx] + insertion + s[idx:]
    kconfig.write_text(s, encoding="utf-8")
    print("Kconfig: SUSFS menu added with all config options")
    return True


def modify_init_c():
    """Add SUSFS support to init.c."""
    init_c = KSU_KERNEL / "core" / "init.c"
    if not init_c.exists():
        print(f"ERROR: {init_c} not found, cannot integrate SUSFS for KernelSU", file=sys.stderr)
        return False
    s = init_c.read_text(encoding="utf-8")
    changed = False

    # Step 1: add #include <linux/susfs.h>
    # Try several possible scheduler-header anchors
    include_added = False
    for marker in ("#include <linux/sched.h>", "#include <linux/sched/task.h>",
                   "#include <linux/sched/signal.h>", "#include <linux/sched/wake_q.h>"):
        if "#include <linux/susfs.h>" in s:
            include_added = True
            break
        if marker in s:
            s = s.replace(marker, marker + "\n#include <linux/susfs.h>", 1)
            include_added = True
            print(f"init.c: added #include <linux/susfs.h> after {marker}")
            changed = True
            break
    if not include_added and "#include <linux/susfs.h>" not in s:
        print("WARNING: no suitable scheduler-header anchor found; skipping #include <linux/susfs.h> insertion", file=sys.stderr)

    # Step 2: remove ksu_syscall_hook_manager_init() / ksu_syscall_hook_init()
    for hook_call in ("ksu_syscall_hook_manager_init();", "ksu_syscall_hook_init();",
                      "ksu_syscall_hook_manager_init ();", "ksu_syscall_hook_init ();"):
        count_before = s.count(hook_call)
        if count_before > 0:
            replacement = (
                "#if defined(CONFIG_KSU_SUSFS)\n"
                "    susfs_init();\n"
                "    #endif"
            )
            s = s.replace(hook_call, replacement)
            print(f"init.c: replaced {count_before} occurrence(s) of {hook_call}", file=sys.stderr)
            changed = True

    # Step 3: if susfs_init() is still missing, insert it into the kernelsu_init() function body
    if "susfs_init()" not in s:
        # Try several function-name patterns
        func_found = False
        for func_pattern in ("kernelsu_init(", "ksu_init(", "init_kernelsu("):
            idx = s.find(func_pattern)
            if idx >= 0:
                func_found = True
                ret_idx = s.find("return 0;", idx)
                if ret_idx >= 0:
                    insertion = (
                        "\n    #ifdef CONFIG_KSU_SUSFS\n"
                        "    susfs_init();\n"
                        "    #endif\n"
                    )
                    s = s[:ret_idx] + insertion + s[ret_idx:]
                    changed = True
                    print("init.c: inserted susfs_init() into kernelsu_init()", file=sys.stderr)
                else:
                    print("WARNING: return 0; not found in kernelsu_init(); skipping susfs_init() insertion", file=sys.stderr)
                break
        if not func_found:
            print("WARNING: kernelsu_init() function not found; skipping susfs_init() insertion", file=sys.stderr)

    if changed:
        init_c.write_text(s, encoding="utf-8")
        print("init.c: SUSFS support added")
        return True
    elif "susfs_init()" in s and "#include <linux/susfs.h>" in s:
        print("init.c: SUSFS support already present")
        return True
    else:
        print("init.c: SUSFS support could not be added", file=sys.stderr)
        return False


def modify_kbuild():
    """Remove obsolete hook compilation units from Kbuild."""
    kbuild = KSU_KERNEL / "Kbuild"
    if not kbuild.exists():
        print(f"WARNING: {kbuild} not found, skipping Kbuild cleanup", file=sys.stderr)
        return True
    s = kbuild.read_text(encoding="utf-8")
    changed = False
    # Match upstream 10_enable_susfs_for_ksu.patch: remove all
    # hook compilation units that conflict with SUSFS, including top-level and architecture-specific lines inside ifeq blocks
    for obj in (
        "kernelsu-objs += hook/lsm_hook.o",
        "kernelsu-objs += hook/syscall_event_bridge.o",
        "kernelsu-objs += hook/syscall_hook_manager.o",
        "kernelsu-objs += hook/tp_marker.o",
        "kernelsu-objs += hook/arm64/patch_memory.o",
        "kernelsu-objs += hook/arm64/syscall_hook.o",
        "kernelsu-objs += hook/x86_64/patch_memory.o",
        "kernelsu-objs += hook/x86_64/syscall_hook.o",
        "kernelsu-objs += hook/riscv64/patch_memory.o",
        "kernelsu-objs += hook/riscv64/syscall_hook.o",
    ):
        count = s.count(obj)
        if count > 0:
            s = s.replace(obj + "\n", "", count)
            changed = True
    if changed:
        kbuild.write_text(s, encoding="utf-8")
        print("Kbuild: old hook objects removed")
    else:
        print("Kbuild: no old hook objects found")
    return True


def main():
    kconfig_ok = modify_kconfig()
    init_ok = modify_init_c()
    kbuild_ok = modify_kbuild()

    # init.c is critical: without susfs_init(), SUSFS is not initialized
    if not init_ok:
        print("ERROR: could not integrate SUSFS into KernelSU init.c; stopping the build", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
