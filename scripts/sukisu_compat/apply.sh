#!/usr/bin/env bash
# Kernel API compatibility patches for SukiSU source (applies to SukiSU-Ultra builtin and main branches)
#
# Background:
#   1) 1) The builtin branch's kernel/hook/lsm_hook.c still uses the old signature
#         security_add_hooks(hooks, count, "ksu") to register LSM hooks;
#         kernels 6.8 and later require (hooks, count, const struct lsm_id *),
#         causing android16-6.12 GKI builds to fail with -Wincompatible-pointer-types (-Werror);
#   2) 2) The builtin branch calls disable_seccomp() for the manager and authorized apps during app startup,
#         so the manager's "Seccomp status" shows "Not enabled". Change this to match main/BakaSU's
#         filtering mode (keep the seccomp filter and allow reboot through the action cache).
#
# Adaptations removed after upstream fixes (verified against builtin 5ef32ad / main 31255c4):
#   - Missing arch.h: builtin now includes kernel/arch.h (byte-for-byte identical to this repository's former copy)
#   - Missing EVENT_SERVICES / duplicate declaration in rules.c: fixed upstream in builtin with UAPI 6
#   - pkg_observer track_throne(TRACK_THRONE_FORCE_SYNCHRONOUS): reverted to false
#   - KSU_IOCTL_KPM typo / missing KSU_IOCTL_MANAGER declaration in supercall.h:
#     upstream merged KPM / MANAGER and others into KSU_IOCTL_EXTENSION; the old constants no longer exist
#   - Bare return / pkg scope in throne_tracker crown_manager: fixed upstream
#   - netlink_kernel_cfg.cb_mutex (removed in Linux 6.11): upstream now detects it at build time
#     the target netlink.h and defines KSU_NETLINK_CFG_HAS_CB_MUTEX; super_access.c
#     guards the member with #ifdef (main: kernel/Kbuild / builtin: kernel/Makefile)
#
# All fixes are guarded by content checks, automatically skipped after upstream fixes, and safe to rerun.
#
# Usage: apply.sh [KernelSU directory] (the caller's working directory must be $KERNEL_ROOT)

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=SukiSU compatibility patch skipped::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU API compatibility patch** was skipped automatically: $1 (build continues)" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

[ -d "$KSU_DIR" ] || fail "KernelSU directory not found: $KSU_DIR"

COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LSM_FILE="$KSU_DIR/kernel/hook/lsm_hook.c"
if [ -f "$LSM_FILE" ] && grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$LSM_FILE"; then
  if grep -q 'ksu_lsm_id' "$LSM_FILE"; then
    echo "lsm_hook.c already contains lsm_id compatibility code; skipping"
  else
    echo "Applying lsm_id compatibility patch (security_add_hooks signature for 6.8+)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-lsm-id-6.8.patch" \
      || fail "Failed to apply the lsm_id compatibility patch (SukiSU upstream source may have changed)"
    grep -q 'struct lsm_id ksu_lsm_id' "$LSM_FILE" \
      || fail "Validation failed after applying the lsm_id compatibility patch"
    echo "lsm_hook.c: switched to struct lsm_id registration for 6.8+"
  fi
else
  echo "lsm_hook.c does not exist or does not need the lsm_id compatibility patch; skipping"
fi

# ---- Seccomp filtering mode (builtin branch)----
# Background: during app startup (zygote setresuid hook), the builtin branch directly calls disable_seccomp() for the manager and authorized apps,
# authorized apps, clearing the manager process's seccomp filter;
# the manager's "Seccomp status" then shows "Not enabled". The corresponding implementation in main/BakaSU
# keeps the filter ("Filtering mode") and uses the seccomp action cache (backported to GKI 5.10+) only to
# allow reboot.
# Implementation: rewrite six disable_seccomp() call sites in lsm_hook.c to use cache-allow,
# copy infra/seccomp_cache.c/h and include them in ksu.c (renamed ksu_main.c after an upstream refactor); keep the filter on >=5.10,
# and preserve the original disable_seccomp() behavior on <5.10 (the action cache is unavailable).
# Guard: run only when builtin handle_zygote_setresuid is present; skip the main branch automatically.
# Skip idempotently after an upstream fix.
if [ -f "$LSM_FILE" ] && grep -q 'handle_zygote_setresuid' "$LSM_FILE"; then
  if grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE"; then
    echo "lsm_hook.c already contains seccomp filtering-mode logic; skipping"
  else
    echo "Applying seccomp filtering-mode patch (match main/BakaSU: keep seccomp filters for the manager and authorized apps)..."
    [ -d "$KSU_DIR/kernel/infra" ] || fail "$KSU_DIR/kernel/infra directory not found; SukiSU builtin structure may have changed"
    cp "$COMPAT_DIR/seccomp_cache.h" "$KSU_DIR/kernel/infra/seccomp_cache.h" \
      || fail "Failed to copy seccomp_cache.h"
    cp "$COMPAT_DIR/seccomp_cache.c" "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "Failed to copy seccomp_cache.c"
    python3 "$COMPAT_DIR/seccomp_filter_mode.py" "$KSU_DIR" \
      || fail "Failed to apply the seccomp filtering-mode patch (SukiSU builtin upstream source may have changed)"
    grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE" \
      || fail "Validation failed after applying the seccomp filtering-mode patch (lsm_hook.c)"
    # The aggregate source file was renamed upstream (kernel/ksu.c -> kernel/ksu_main.c); validate the actual path
    KSU_AGG=""
    for cand in kernel/ksu.c kernel/ksu_main.c; do
      if [ -f "$KSU_DIR/$cand" ]; then
        KSU_AGG="$KSU_DIR/$cand"
        break
      fi
    done
    if [ -z "$KSU_AGG" ] || ! grep -q '#include "infra/seccomp_cache.c"' "$KSU_AGG"; then
      fail "Validation failed after applying the seccomp filtering-mode patch (aggregate source file ksu.c/ksu_main.c)"
    fi
    grep -q '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "seccomp_cache.c version guard validation failed"
    echo "Seccomp filtering mode enabled: the manager's Seccomp status will show \"Filtering mode\""
  fi
else
  echo "lsm_hook.c has no builtin setresuid path (the main branch already includes filtering mode); skipping the seccomp filtering-mode patch"
fi

# ---- clang fall-through annotation ----
# The builtin policy/allowlist.c uses comment-style fall-through; Bazel GKI
# builds with -Werror,-Wimplicit-fallthrough fail. Replace it with the kernel's
# fallthrough macro (expands to __attribute__((__fallthrough__))) and skip automatically after an upstream fix.
if grep -rqF '/* fall through */' "$KSU_DIR/kernel" 2>/dev/null; then
  echo "Fixing comment-style fall-through in SukiSU source (Bazel -Werror compatibility)..."
  python3 - "$KSU_DIR" <<'PYEOF'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / "kernel"
for path in sorted(root.rglob("*.c")):
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    if "/* fall through */" not in text:
        continue
    path.write_text(
        text.replace("/* fall through */", "fallthrough;"),
        encoding="utf-8",
        errors="surrogateescape",
    )
    print(f"  {path}")
PYEOF
  if grep -rqF '/* fall through */' "$KSU_DIR/kernel" 2>/dev/null; then
    fail "fall-through annotation remains after the fix"
  fi
  echo "fall-through annotation fix complete"
else
  echo "No comment-style fall-through in SukiSU source; skipping"
fi

echo "SukiSU API compatibility patch processing complete"
