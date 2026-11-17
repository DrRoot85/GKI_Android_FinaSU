#!/usr/bin/env bash
# SukiSU-Nova kernel source API compatibility patches (for builtin and main branches).
#
# Background:
#   1) The builtin branch still registers LSM hooks in kernel/hook/lsm_hook.c using
#      the old security_add_hooks(hooks, count, "ksu") signature. Kernels 6.8+ require
#      (hooks, count, const struct lsm_id *), causing -Wincompatible-pointer-types
#      (-Werror) when building the android16-6.12 GKI.
#   2) The builtin branch calls disable_seccomp() for the manager and authorized apps
#      during app startup, clearing the manager's own filter and showing "Not enabled"
#      for "Seccomp status" on the manager home screen. Align it with main/BakaSU's
#      filter mode (preserve the seccomp filter and use the action cache to allow reboot).
#
# Adaptations removed here after upstream fixes (verified against builtin 5ef32ad / main 31255c4):
#   - Missing arch.h: builtin now includes kernel/arch.h (byte-identical to our old copy).
#   - Missing EVENT_SERVICES / duplicate rules.c declarations: fixed in builtin with UAPI 6.
#   - pkg_observer track_throne(TRACK_THRONE_FORCE_SYNCHRONOUS): reverted to false.
#   - KSU_IOCTL_KPM typo / missing KSU_IOCTL_MANAGER declaration in supercall.h:
#     upstream merged KPM, MANAGER, etc. into KSU_IOCTL_EXTENSION; old constants are gone.
#   - Bare return / pkg scope in throne_tracker's crown_manager: fixed upstream.
#   - netlink_kernel_cfg.cb_mutex (removed in Linux 6.11): upstream now probes the target
#     netlink.h at build time, defines KSU_NETLINK_CFG_HAS_CB_MUTEX, and guards the member
#     in super_access.c with #ifdef (main: kernel/Kbuild; builtin: kernel/Makefile).
#
# Every fix is guarded by content checks, so it is skipped after upstream fixes it and is idempotent.
#
# Usage: apply.sh [KernelSU directory] (the caller's working directory must be $KERNEL_ROOT).

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=SukiSU-Nova compatibility patch skipped::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU-Nova API compatibility patch** skipped automatically: $1 (build continues)" >> "$GITHUB_STEP_SUMMARY"
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
    echo "lsm_hook.c already contains the lsm_id compatibility code; skipping"
  else
    echo "Applying the lsm_id compatibility patch (new security_add_hooks signature for 6.8+)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-lsm-id-6.8.patch" \
      || fail "failed to apply the lsm_id compatibility patch (SukiSU-Nova upstream code may have changed)"
    grep -q 'struct lsm_id ksu_lsm_id' "$LSM_FILE" \
      || fail "validation failed after applying the lsm_id compatibility patch"
    echo "lsm_hook.c: switched to struct lsm_id registration for 6.8+"
  fi
else
  echo "lsm_hook.c is missing or does not need the lsm_id compatibility patch; skipping"
fi

# ---- Seccomp filter mode (builtin branch) ----
# Background: the builtin branch directly calls disable_seccomp() for the manager and
# authorized apps in the app startup path (zygote setresuid hook), clearing the manager's
# own seccomp filter and showing "Not enabled" for "Seccomp status" on the manager home
# screen. Like main/BakaSU, preserve the filter ("filter mode") and use the seccomp action
# cache (backported from GKI 5.10+) only to allow reboot.
# Change: convert six disable_seccomp() call sites in lsm_hook.c to cache-allow logic,
# distribute infra/seccomp_cache.c/h, and aggregate-compile it in ksu.c (renamed upstream
# to ksu_main.c). Preserve the filter on >=5.10; retain the original disable_seccomp()
# behavior on <5.10, where the action cache is unavailable.
# Guard: run only when the builtin handle_zygote_setresuid path is present; skip main
# automatically, and skip idempotently if upstream has already fixed the code.
if [ -f "$LSM_FILE" ] && grep -q 'handle_zygote_setresuid' "$LSM_FILE"; then
  if grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE"; then
    echo "lsm_hook.c already contains seccomp filter-mode logic; skipping"
  else
    echo "Applying the seccomp filter-mode patch (aligning with main/BakaSU: preserve filters for the manager and authorized apps)..."
    [ -d "$KSU_DIR/kernel/infra" ] || fail "$KSU_DIR/kernel/infra directory not found; the SukiSU-Nova builtin structure may have changed"
    cp "$COMPAT_DIR/seccomp_cache.h" "$KSU_DIR/kernel/infra/seccomp_cache.h" \
      || fail "failed to copy seccomp_cache.h"
    cp "$COMPAT_DIR/seccomp_cache.c" "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "failed to copy seccomp_cache.c"
    python3 "$COMPAT_DIR/seccomp_filter_mode.py" "$KSU_DIR" \
      || fail "failed to apply the seccomp filter-mode patch (SukiSU-Nova builtin upstream code may have changed)"
    grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE" \
      || fail "validation failed after applying the seccomp filter-mode patch (lsm_hook.c)"
    # The aggregate compilation file was renamed upstream (kernel/ksu.c -> kernel/ksu_main.c); validate its actual path.
    KSU_AGG=""
    for cand in kernel/ksu.c kernel/ksu_main.c; do
      if [ -f "$KSU_DIR/$cand" ]; then
        KSU_AGG="$KSU_DIR/$cand"
        break
      fi
    done
    if [ -z "$KSU_AGG" ] || ! grep -q '#include "infra/seccomp_cache.c"' "$KSU_AGG"; then
      fail "validation failed after applying the seccomp filter-mode patch (aggregate compilation file ksu.c/ksu_main.c)"
    fi
    grep -q '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "seccomp_cache.c version-guard validation failed"
    echo "seccomp filter mode enabled: the manager home screen will show \"Filter mode\" for Seccomp status"
  fi
else
  echo "lsm_hook.c has no builtin setresuid path (filter mode is already built into the main branch); skipping the seccomp filter-mode patch"
fi

# ---- clang fall-through annotation ----
# The builtin policy/allowlist.c uses comment-based fall-through annotations, which
# fail Bazel GKI builds with -Werror,-Wimplicit-fallthrough. Replace them with the kernel
# fallthrough macro (expands to __attribute__((__fallthrough__))); skip after upstream fixes it.
if grep -rqF '/* fall through */' "$KSU_DIR/kernel" 2>/dev/null; then
  echo "Replacing comment-based fall-through in SukiSU-Nova sources (Bazel -Werror compatibility)..."
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
    fail "comment-based fall-through annotations remain after replacement"
  fi
  echo "fall-through annotations replaced"
else
  echo "No comment-based fall-through annotations in SukiSU-Nova sources; skipping"
fi

# ---- 6.12+ LSM static-call slot (builtin branch) ----
# Background: the 6.12 LSM framework precompiles each hook callback into a static-call
# table whose width is MAX_LSM_COUNT, computed at build time from the number of built-in LSMs.
# security_add_hooks() panics when lsm_active_cnt >= MAX_LSM_COUNT ("Too many LSMs registered").
# GKI gki_defconfig enables exactly five LSMs (capabilities/selinux/safesetid/bpf_lsm/landlock),
# so MAX_LSM_COUNT == 5 and all slots are occupied at boot.
# The builtin branch still registers its own LSM from device_initcall in hook/lsm_hook.c.
# This becomes the sixth LSM and triggers the panic (main/FinaSU now rewrite a static-call
# slot at runtime without consuming a new slot). The device hangs on the first boot screen,
# and the panic produces no log on disk (PANIC_TIMEOUT=-1).
# Change: reserve an explicit KSU slot in MAX_LSM_COUNT (KSU_ENABLED 1,), widening the
# static-call table by one column so KSU registration can use the free slot.
# Guard: run only when the kernel enables the static-call LSM framework (the panic exists
# in security/security.c) and the KSU driver still calls security_add_hooks(); skip once
# upstream switches to slot rewriting.
LSM_ROOT="${KERNEL_ROOT:-.}"
LSM_COUNT_FILE="$LSM_ROOT/common/include/linux/lsm_count.h"
LSM_PANIC_GUARD="$LSM_ROOT/common/security/security.c"
if [ -f "$LSM_COUNT_FILE" ] && [ -f "$LSM_PANIC_GUARD" ] \
  && grep -qs 'Too many LSMs registered' "$LSM_PANIC_GUARD" \
  && grep -qs 'security_add_hooks(ksu_hooks' "$KSU_DIR/kernel/hook/lsm_hook.c"; then
  if grep -q 'KSU_ENABLED' "$LSM_COUNT_FILE"; then
    echo "lsm_count.h already contains the KSU slot; skipping"
  else
    echo "Reserving an LSM static-call slot for built-in KSU (MAX_LSM_COUNT + 1)..."
    python3 - "$LSM_COUNT_FILE" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="surrogateescape").read()

block = """/*
 * KernelSU registers its own LSM from device_initcall, after every built-in
 * LSM has taken its static call slot. Reserve one extra column so that
 * security_add_hooks() finds a free slot instead of panicking with
 * "Too many LSMs registered".
 */
#if IS_ENABLED(CONFIG_KSU)
#define KSU_ENABLED 1,
#else
#define KSU_ENABLED
#endif

"""

anchor = "#define MAX_LSM_COUNT"
idx = text.find(anchor)
if idx < 0:
    sys.exit("MAX_LSM_COUNT not found")

text = text[:idx] + block + text[idx:]

open_brace = text.find("COUNT_LSMS(", idx)
if open_brace < 0:
    sys.exit("COUNT_LSMS not found")
line_end = text.find("\n", open_brace)
text = text[:line_end + 1] + "\t\tKSU_ENABLED\t\t\\\n" + text[line_end + 1:]

open(path, "w", encoding="utf-8", errors="surrogateescape").write(text)
print("  lsm_count.h: MAX_LSM_COUNT expanded by one slot for KSU")
PYEOF
    grep -q 'KSU_ENABLED' "$LSM_COUNT_FILE" \
      || fail "validation failed after adding the KSU slot to lsm_count.h"
  fi
else
  echo "No lsm_count.h or KSU does not use security_add_hooks; skipping LSM slot reservation"
fi

echo "SukiSU-Nova API compatibility patches complete"
