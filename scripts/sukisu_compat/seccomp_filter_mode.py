#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convert the builtin branch to seccomp filtering mode.

Background:
    During app startup (zygote setresuid hook, kernel/hook/lsm_hook.c), SukiSU-Ultra's builtin branch
    directly calls disable_seccomp() for the manager and authorized apps,
    clearing the manager process's seccomp filter so the manager's home screen
    shows "Seccomp status: Not enabled". The corresponding implementation in main/BakaSU is to
    keep the filter ("Filtering mode") and allow reboot only through the seccomp action cache.

Implementation:
  1. kernel/hook/lsm_hook.c:      Rewrite six disable_seccomp() call sites as
          ">=5.10 keep the filter and allow reboot / <5.10 retain disable_seccomp()"
          (the seccomp action cache is backported to GKI 5.10+ kernels, matching BakaSU);
          also add the infra/seccomp_cache.h prototype declaration at the top of the file.
  2.   2. Aggregate source file (kernel/ksu.c, renamed to kernel/ksu_main.c by the upstream refactor on 2026-10-19):
          Include infra/seccomp_cache.c after infra/event_queue.c (builtin is a single compilation unit).

All replacements verify the exact match count and fail if upstream code changes; the script is idempotent and safe to rerun.
Usage: python3 seccomp_filter_mode.py <KernelSU directory>
"""

import re
import sys
from pathlib import Path

# Replacement block that keeps the filter (preprocessor directives at column 0, matching upstream BakaSU)
CACHE_BLOCK = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
    "        if (current->seccomp.mode == SECCOMP_MODE_FILTER && current->seccomp.filter) {\n"
    "            spin_lock_irq(&current->sighand->siglock);\n"
    "            ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);\n"
    "            spin_unlock_irq(&current->sighand->siglock);\n"
    "        }\n"
    "#else\n"
    "        disable_seccomp();\n"
    "#endif"
)

# (compiled regex, expected match count, description)
# SUSFS path: one manager and one authorized-app call in each of handle_zygote_setresuid / handle_zygote_next_setresuid
# Non-SUSFS path: one call in each ksu_task_fix_setuid branch
LSM_RULES = [
    (re.compile(
        r'(if \(likely\(ksu_is_manager_appid_valid\(\)\) && unlikely\(is_uid_manager\(ruid\)\)\) \{\n)'
        r'        disable_seccomp\(\);'),
     2, "SUSFS manager branch"),
    (re.compile(
        r'(if \(ksu_is_allow_uid_for_current\(ruid\)\) \{\n)'
        r'        disable_seccomp\(\);'),
     2, "SUSFS authorized-app branch"),
    (re.compile(
        r'(if \(unlikely\(is_uid_manager\(new_uid\)\)\) \{\n)'
        r'        disable_seccomp\(\);'),
     1, "Non-SUSFS manager branch"),
    (re.compile(
        r'(if \(ksu_is_allow_uid_for_current\(new_uid\)\) \{\n)'
        r'        disable_seccomp\(\);'),
     1, "Non-SUSFS authorized-app branch"),
]

KSU_ANCHOR = re.compile(r'(#include "infra/event_queue\.c"\n)')


def patch_lsm(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    total = 0
    for pattern, expected, name in LSM_RULES:
        text, n = pattern.subn(lambda m: m.group(1) + CACHE_BLOCK, text)
        if n != expected:
            sys.exit(f"::error::lsm_hook.c {name}: matched {n} occurrence(s) (expected {expected}); "
                     f"SukiSU builtin upstream code may have changed; update the patch")
        total += n
    if '#include "infra/seccomp_cache.h"' not in text:
        text = '#include "infra/seccomp_cache.h"\n\n' + text
    path.write_text(text, encoding="utf-8")
    print(f"lsm_hook.c: converted {total} disable_seccomp() call site(s) to filtering mode")


def patch_ksu(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if '#include "infra/seccomp_cache.c"' in text:
        print(f"{path.name}: seccomp_cache.c is already included for aggregate compilation; skipping")
        return
    text, n = KSU_ANCHOR.subn(
        lambda m: m.group(1) + '#include "infra/seccomp_cache.c"\n', text)
    if n != 1:
        sys.exit(f"::error::{path.name}: infra/event_queue.c aggregate anchor not found; "
                 "SukiSU builtin upstream code may have changed; update the patch")
    path.write_text(text, encoding="utf-8")
    print(f"{path.name}: added infra/seccomp_cache.c to aggregate compilation")


def find_aggregate(kdir: Path) -> Path | None:
    # The 2026-10-19 upstream refactor renamed kernel/ksu.c to kernel/ksu_main.c; support both names
    for name in ("ksu.c", "ksu_main.c"):
        p = kdir / "kernel" / name
        if p.is_file():
            return p
    return None


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} <KernelSU directory>")
    kdir = Path(sys.argv[1])
    lsm = kdir / "kernel" / "hook" / "lsm_hook.c"
    ksu = find_aggregate(kdir)
    if not lsm.is_file() or ksu is None:
        sys.exit(f"::error::Could not find {lsm} or kernel/{{ksu,ksu_main}}.c; "
                 "SukiSU builtin directory structure may have changed")
    patch_lsm(lsm)
    patch_ksu(ksu)


if __name__ == "__main__":
    main()
