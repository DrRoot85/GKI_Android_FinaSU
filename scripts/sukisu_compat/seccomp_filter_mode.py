#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Adapt seccomp filtering for the builtin branch.

Background:
  On the SukiSU-Nova builtin branch, the app startup path (the zygote setresuid hook
  in kernel/hook/lsm_hook.c) directly calls disable_seccomp() for the manager and
  authorized apps. This clears the manager process's own seccomp filter, causing
  "Seccomp status" on the manager home screen to show "Not enabled". The main branch
  and BakaSU instead preserve the filter ("filter mode") and use the seccomp action
  cache only to allow reboot.

Changes:
  1. Replace six disable_seccomp() call sites in kernel/hook/lsm_hook.c with logic to
     preserve the filter and allow reboot on >=5.10, while retaining disable_seccomp()
     on <5.10. (The seccomp action cache is backported from GKI 5.10+ and matches BakaSU.)
     Also add the infra/seccomp_cache.h prototype declaration at the file header.
  2. In the aggregate compilation file (kernel/ksu.c, renamed upstream to
     kernel/ksu_main.c after the 2026-10-19 refactor), aggregate-compile
     infra/seccomp_cache.c after infra/event_queue.c (builtin builds as one translation unit).

Every replacement validates the exact match count and exits if upstream changes (idempotent).
Usage: python3 seccomp_filter_mode.py <KernelSU directory>
"""

import re
import sys
from pathlib import Path

# Replacement block that preserves the filter (preprocessor directives start at column 0, matching upstream BakaSU).
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
# SUSFS path: one manager and one authorized-app site each in handle_zygote_setresuid / handle_zygote_next_setresuid.
# Non-SUSFS path: one site each in ksu_task_fix_setuid.
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
     1, "non-SUSFS manager branch"),
    (re.compile(
        r'(if \(ksu_is_allow_uid_for_current\(new_uid\)\) \{\n)'
        r'        disable_seccomp\(\);'),
     1, "non-SUSFS authorized-app branch"),
]

KSU_ANCHOR = re.compile(r'(#include "infra/event_queue\.c"\n)')


def patch_lsm(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    total = 0
    for pattern, expected, name in LSM_RULES:
        text, n = pattern.subn(lambda m: m.group(1) + CACHE_BLOCK, text)
        if n != expected:
            sys.exit(f"::error::lsm_hook.c {name}: found {n} match(es) (expected {expected}); "
                     f"SukiSU-Nova builtin upstream code may have changed; update the patch.")
        total += n
    if '#include "infra/seccomp_cache.h"' not in text:
        text = '#include "infra/seccomp_cache.h"\n\n' + text
    path.write_text(text, encoding="utf-8")
    print(f"lsm_hook.c: converted {total} disable_seccomp() call site(s) to filter mode")


def patch_ksu(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if '#include "infra/seccomp_cache.c"' in text:
        print(f"{path.name}: seccomp_cache.c is already aggregate-compiled; skipping")
        return
    text, n = KSU_ANCHOR.subn(
        lambda m: m.group(1) + '#include "infra/seccomp_cache.c"\n', text)
    if n != 1:
        sys.exit(f"::error::{path.name}: missing the infra/event_queue.c aggregation anchor; "
                 "SukiSU-Nova builtin upstream code may have changed; update the patch.")
    path.write_text(text, encoding="utf-8")
    print(f"{path.name}: added infra/seccomp_cache.c to aggregate compilation")


def find_aggregate(kdir: Path) -> Path | None:
    # Upstream renamed kernel/ksu.c to kernel/ksu_main.c in the 2026-10-19 refactor; support both names.
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
        sys.exit(f"::error::could not find {lsm} or kernel/{{ksu,ksu_main}}.c; "
                 "the SukiSU-Nova builtin directory structure may have changed.")
    patch_lsm(lsm)
    patch_ksu(ksu)


if __name__ == "__main__":
    main()
