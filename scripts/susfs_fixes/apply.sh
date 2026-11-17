#!/usr/bin/env bash
# Apply the SUSFS patch and context fixes required by each kernel version
#
# Required environment variables:
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# Set the working directory to $KERNEL_ROOT before calling this script
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# List sorted relative paths of .rej files in the current directory that are not from upstream.
# An upstream branch may contain committed .rej files (for example, mm/rmap.c.rej in android15-6.6-2026-04);
# these are leftovers from upstream merge-conflict resolution, not conflicts from this patch. A failed patch can overwrite them,
# so treat a file as upstream-provided only if it is tracked by Git and unmodified.
# Outside a Git repository (local testing), Git commands return nothing; fall back to listing all .rej files
list_upstream_rej() {
  git ls-files -- '*.rej' 2>/dev/null | while IFS= read -r f; do
    git diff --quiet -- "$f" 2>/dev/null && echo "$f"
  done
}
list_untracked_rej() {
  comm -23 \
    <(find . -type f -name '*.rej' | sed 's|^\./||' | sort) \
    <(list_upstream_rej | sort)
}

echo "Applying SUSFS patch..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

# feat/usb-arsenal: on kernels before i_user_ns() (5.10/5.15/older 6.1), replace i_uid_into_mnt(i_user_ns(...), ...)
# with i_uid_into_mnt(&init_user_ns, ...); otherwise clang -Werror reports an implicit declaration.
if [[ "$KERNEL_VERSION" == "5.10" || "$KERNEL_VERSION" == "5.15" ]]; then
  if [ -f fs/susfs.c ]; then
    echo "Applying susfs_idmap_compat.py (${KERNEL_VERSION} has no i_user_ns())"
    python3 "$SCRIPT_DIR/susfs_idmap_compat.py" "$PWD/common/fs/susfs.c"
  fi
fi

# FinaSU upstream has natively integrated SUSFS in-tree since cdf8711a + 5b83330b (2026-10-23); the official
# docs/builtin-integration.md explicitly says **not** to apply susfs4ksu's
# 10_enable_susfs_for_ksu.patch (it targets upstream KernelSU's manual-hook model and removes
# hook/tp_marker.o and other compilation units from Kbuild, while FinaSU's kprobe model still references these
# symbols, so applying the driver-side patch causes undefined-symbol errors when linking vmlinux).
# FinaSU now matches SukiSU/BakaSU: no driver-side patch. The only difference is that FinaSU's
# native integration is newer, so validate its structure here (the kernel-side 50_add main patch's inline hooks depend on
# these entry points/symbols); fail immediately on drift instead of silently degrading.
verify_finasu_native_susfs() {
  local FINASU_KSU="$KERNEL_ROOT/KernelSU/kernel"
  local OPT SYM

  if [ ! -f "$FINASU_KSU/extension/susfs.c" ]; then
    echo "::error::FinaSU does not include native SUSFS integration (KernelSU/kernel/extension/susfs.c is missing)." >&2
    echo "::error::The checked-out FinaSU revision predates 5b83330b (2026-10-23), or upstream has changed its structure again;" >&2
    echo "::error::the old 10_enable driver-side patch is obsolete after upstream's native integration; ensure ksuCommit points to the latest Release." >&2
    exit 1
  fi

  # Kconfig must contain the complete KSU_SUSFS menu (all CONFIG_KSU_SUSFS* options written by Add SUSFS Configuration
  # must be defined or olddefconfig silently drops them)
  for OPT in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
             KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
             KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP; do
    grep -q "^config $OPT\$" "$FINASU_KSU/Kconfig" \
      || { echo "::error::FinaSU Kconfig is missing config $OPT (upstream structure may have changed)" >&2; exit 1; }
  done

  # extension/susfs.c provides entry points called inline by the 50_add main patch in fs/exec.c;
  # in newer FinaSU versions, the preinit entry point moved to kernel/preinit/preinit.c; support the older layout too.
  for SYM in ksu_handle_execveat ksu_handle_execveat_sucompat ksu_handle_post_execveat_sucompat; do
    grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/extension/susfs.c" \
      || { echo "::error::FinaSU extension/susfs.c is missing global entry point: $SYM" >&2; exit 1; }
  done

  for SYM in ksu_setup_preinit_file ksu_preinit_handle_post_execveat; do
    if grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/preinit/preinit.c" 2>/dev/null; then
      continue
    fi
    grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/extension/susfs.c" \
      || { echo "::error::FinaSU is missing global entry point: $SYM (checked preinit/preinit.c and extension/susfs.c)" >&2; exit 1; }
  done

  # Three-argument SUSFS implementation (the kernel-side three-argument call in kernel/sys.c depends on this signature)
  grep -q '^int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)$' "$FINASU_KSU/hook/setuid_hook.c" \
    || { echo "::error::FinaSU setuid_hook.c is missing the three-argument ksu_handle_setresuid (upstream structure may have changed)" >&2; exit 1; }

  # my_* symbols are globally exported (the 6.6/6.12 main patch calls them inline in security/selinux/{hooks,selinuxfs}.c)
  for SYM in my_write_context my_write_access my_setprocattr; do
    grep -qE "^(ssize_t|int) $SYM\(" "$FINASU_KSU/feature/selinux_hide.c" \
      || { echo "::error::FinaSU selinux_hide.c does not globally export $SYM (the inline SUSFS SELinux hook will fail to link)" >&2; exit 1; }
  done

  # susfs_init() is called natively by the driver init
  grep -q 'susfs_init();' "$FINASU_KSU/core/init.c" \
    || { echo "::error::FinaSU init.c does not call susfs_init() (upstream structure may have changed)" >&2; exit 1; }

  echo "FinaSU native SUSFS integration validation passed"
}

# Native KernelSU SUSFS integration validation: confirm 10_enable_susfs_for_ksu.patch applied successfully,
# meaning KernelSU replaced kprobe/LSM hooks with SUSFS, init.c calls susfs_init(),
# and Kbuild no longer contains obsolete hook compilation units (to avoid conflicts with the main SUSFS patch).
# If automatic integration fails due to upstream structure differences, stop the build instead of silently producing a kernel without SUSFS.
verify_kernelsu_susfs() {
  local KSU_KERNEL="$KERNEL_ROOT/KernelSU/kernel"

  if [ ! -f "$KSU_KERNEL/core/init.c" ]; then
    echo "::error::KernelSU does not contain core/init.c; cannot integrate SUSFS" >&2
    exit 1
  fi

  # init.c should call susfs_init() instead of ksu_syscall_hook_init()
  if ! grep -q 'susfs_init()' "$KSU_KERNEL/core/init.c"; then
    echo "::error::KernelSU init.c does not call susfs_init(); SUSFS integration is incomplete" >&2
    exit 1
  fi

  if grep -qE 'ksu_syscall_hook(_manager)?_init();' "$KSU_KERNEL/core/init.c"; then
    echo "::error::KernelSU init.c still calls ksu_syscall_hook*_init(); SUSFS integration is incomplete" >&2
    exit 1
  fi

  # init.c should include linux/susfs.h
  if ! grep -q '#include <linux/susfs.h>' "$KSU_KERNEL/core/init.c"; then
    echo "::error::KernelSU init.c does not include linux/susfs.h; SUSFS integration is incomplete" >&2
    exit 1
  fi

  # Kbuild should no longer contain obsolete hook compilation units (replaced by SUSFS)
  if grep -q 'kernelsu-objs += hook/lsm_hook.o' "$KSU_KERNEL/Kbuild" \
    || grep -q 'kernelsu-objs += hook/tp_marker.o' "$KSU_KERNEL/Kbuild"; then
    echo "::error::KernelSU Kbuild still contains obsolete hook compilation units; SUSFS integration is incomplete" >&2
    exit 1
  fi

  # Kconfig should define the KSU_SUSFS option
  if ! grep -q 'config KSU_SUSFS' "$KSU_KERNEL/Kconfig"; then
    echo "::error::KernelSU Kconfig is missing config KSU_SUSFS; SUSFS integration is incomplete" >&2
    exit 1
  fi

  echo "Native KernelSU SUSFS integration validation passed"
}

case "$KSU_VARIANT" in
  "SukiSU"|"BakaSU")
    echo "SukiSU/BakaSU use built-in SUSFS support"
    ;;
  "FinaSU")
    echo "FinaSU uses native in-tree SUSFS integration (no driver-side patch, same approach as SukiSU/BakaSU)"
    verify_finasu_native_susfs
    ;;
  "KernelSU")
    echo "Native KernelSU uses the SUSFS compatibility patch (requires a manual driver-side patch, matching upstream tiann/KernelSU)"
    verify_kernelsu_susfs
    ;;
esac

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# ---- Normalize the susfs4ksu R28 getpriority/priority UID filter switch ----
# The full implementation of this feature (including the susfs_switch_to_ksu_domain / susfs_restore_creds helper
# functions) is controlled by CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER, but SukiSU (builtin),
# BakaSU, and FinaSU native driver Kconfig do not define this option. Meanwhile, the SukiSU driver's
# supercall dispatch (CMD_SUSFS_SET_PRIORITY_UID_FILTER) and pkg_observer unconditionally call
# susfs_set_priority_uid_filter / susfs_parse_priority_app_strings, causing:
#   - - the two helper functions in susfs.c to lose their only callers, triggering clang -Werror,-Wunused-function
#     and stopping compilation (reproduced with FinaSU/BakaSU/SukiSU);
#   - - declarations are removed from susfs.h, causing -Wimplicit-function-declaration in the SukiSU driver.
# Promote the guard to CONFIG_KSU_SUSFS (always y when SUSFS is enabled) so the feature remains fully available.
# Rewrite only preprocessor directive lines; keep the
# "CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n" string literal in susfs.c's copy_config_to_buf() unchanged so the manager
# can continue to identify the feature by its original name.
normalize_priority_uid_filter_guard() {
  local f
  # The +#ifdef/+#endif lines in the main patch (leave context lines untouched so hunk counts remain valid)
  [[ -f "$SUSFS_PATCH" ]] \
    && sed -i -E '/^[+ ]*#[[:space:]]*(ifdef|ifndef|endif).*CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/ s/CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/CONFIG_KSU_SUSFS/' "$SUSFS_PATCH"
  # Sources and headers copied into the kernel tree
  for f in fs/susfs.c include/linux/susfs.h; do
    [[ -f "$f" ]] || continue
    sed -i -E '/^#[[:space:]]*(ifdef|ifndef|endif).*CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/ s/CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/CONFIG_KSU_SUSFS/' "$f"
  done
}

normalize_priority_uid_filter_guard
echo "Normalized the PRIORITY_UID_FILTER guard to CONFIG_KSU_SUSFS"

# Compatibility for kernels without the VMA padding API: 5.10.66–209, 5.15.74–144, and 6.1.25–68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "Target kernel does not provide VMA_PAD_START; using vma->vm_end to support SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# Temporarily adjust old-kernel source context so the SUSFS main patch can apply
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "Temporarily adjusting Android 12 5.10 base.c context"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "Temporarily adjusting Android 12 5.10 fdinfo.c context"
    adjust_legacy_fdinfo_context
  fi
fi

# Android 13 5.10.107 still uses the old fdinfo context, as do older Android 12 kernels
if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.10" && "$CURRENT_SUB" -le 107 ]]; then
  echo "Temporarily adjusting Android 13 5.10 fdinfo.c context"
  adjust_legacy_fdinfo_context
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "Temporarily adjusting Android 13 5.15 namespace.c/open.c/fdinfo.c context"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  # 5.15.220 (LTS) natively includes #include <trace/hooks/{mm,blk}.h>. After the upstream rebase,
  # the main patch uses these lines as context for the susfs_def.h insertion hunk; the old remove-then-restore
  # workaround causes the entire hunk to be rejected, so do not remove them. Versions missing the context are handled by
  # normalize_trace_ctx.py, which normalizes a copy of the patch.
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "Temporarily adjusting Android 14 6.1 sched.h context"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "Temporarily adjusting Android 14 6.1 dma-buf.h context"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    echo "Temporarily adjusting Android 14 6.1 namespace.c context"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "Temporarily adjusting Android 15 6.6 base.c context"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "Temporarily adjusting Android 15 6.6 memory.c context"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

# The first fs/exec.c hunk in the 6.12 main patch uses `#include <linux/dma-buf.h>` (immediately after ksm.h)
# as the context anchor for inserting susfs_def.h. GKI 6.12.58+ exec.c already has this form,
# so the patch applies directly. 6.12.23–38 lacks this dma-buf.h line, so the hunk is rejected and exec.c
# does not include susfs_def.h; susfs_is_current_proc_no_su() in do_execveat_common()
# becomes an implicit declaration and clang -Werror stops compilation.
# Only modify a copy of the patch when the source lacks this context: remove the stale line and recalculate the hunk counts;
# do not change the source (the old remove-dma-buf.h-then-add-it-at-file-start workaround has been removed).
normalize_exec_include_hunk() {
  python3 - "$SUSFS_PATCH" <<'PYEOF'
import re
import sys

path = sys.argv[1]
src = open("fs/exec.c", encoding="utf-8", errors="surrogateescape").read()
if "#include <linux/ksm.h>\n#include <linux/dma-buf.h>" in src:
    print("fs/exec.c already contains the dma-buf.h anchor; the main patch applies directly, skipping normalization")
    raise SystemExit(0)

with open(path, encoding="utf-8", errors="surrogateescape") as f:
    lines = f.read().splitlines()

hdr = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
out, i, dropped = [], 0, 0

while i < len(lines):
    line = lines[i]
    m = hdr.match(line)
    if not m:
        out.append(line)
        i += 1
        continue

    j = i + 1
    body = []
    while j < len(lines) and not lines[j].startswith(("@@", "diff --git")):
        body.append(lines[j])
        j += 1

    # Process only the hunk that inserts susfs_def.h with dma-buf.h as its context
    if any(l.strip() == "#include <linux/dma-buf.h>" for l in body) \
            and any("susfs_def.h" in l for l in body):
        kept = [l for l in body if l.strip() != "#include <linux/dma-buf.h>"]
        dropped += len(body) - len(kept)
        old = sum(1 for l in kept if l[:1] in (" ", "-"))
        new = sum(1 for l in kept if l[:1] in (" ", "+"))
        line = "@@ -%s,%d +%s,%d @@" % (m.group(1), old, m.group(3), new)
        body = kept

    out.append(line)
    out.extend(body)
    i = j

if dropped:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("\n".join(out) + "\n")
    print("fs/exec.c patch context normalized (removed %d stale dma-buf context line(s))" % dropped)
else:
    print("fs/exec.c patch context does not need normalization")
PYEOF
}

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  echo "Normalizing fs/exec.c header context in the Android 16 6.12 main patch"
  normalize_exec_include_hunk
fi

# After upstream rebased to 5.15.211, the susfs_def.h insertion hunk uses trace/hooks headers
# as context. 5.15.74–5.15.194 source lacks these lines, so the entire hunk is rejected and compilation ultimately fails due to
# implicit SUSFS_IS_INODE_* declarations under clang -Werror. Normalize a copy of the patch based on the actual source.
echo "Normalizing SUSFS header context"
python3 "$SCRIPT_DIR/normalize_trace_ctx.py" "$SUSFS_PATCH"

# ==================== feat/usb-arsenal SUSFS compatibility helpers (required for native KernelSU) ====================
# These scripts come from Bernstein94/AK3_GKI_KernelSU_SUSFS feat/usb-arsenal and help
# the SUSFS main patch apply and compile across sublevels. They are also harmless for SukiSU/BakaSU/FinaSU
# (run only when conditions match and otherwise skipped automatically).

# 1) android16-6.12 sublevel <= 92: adapt the SUSFS main patch to older fs/exec.c /
#    fs/proc/task_mmu.c layouts so the patch applies cleanly.
# Note: the script has already changed to $KERNEL_ROOT/common; use $PWD rather than $PWD/common for paths.
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  CURRENT_SUB="${SUB_LEVEL:-99999}"
  if [[ "$CURRENT_SUB" =~ ^[0-9]+$ ]] && [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "Applying apply_susfs_compat.py for android16-6.12 sublevel ${CURRENT_SUB}"
    python3 "$SCRIPT_DIR/apply_susfs_compat.py" "$PWD" "$SUSFS_PATCH"
  fi
fi

# 2) android15-6.6 sublevel <= 30: change show_smaps_rollup Case 4 to brace syntax
#    to match the SUSFS main patch hunk (apply before patching and revert afterward).
# Note: the working directory is already $KERNEL_ROOT/common; use $PWD/... rather than $PWD/common/....
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  CURRENT_SUB="${SUB_LEVEL:-99999}"
  if [[ "$CURRENT_SUB" =~ ^[0-9]+$ ]] && [[ "$CURRENT_SUB" -le 30 ]]; then
    echo "Applying susfs_fake_66_smaps.py (android15-6.6 sublevel ${CURRENT_SUB})"
    python3 "$SCRIPT_DIR/susfs_fake_66_smaps.py" "$PWD/fs/proc/task_mmu.c" apply
  fi
fi

# 3) android16-6.12 sublevel >= 92: change show_smaps_rollup to its pre-refactor form
#    to match the SUSFS main patch hunk (apply before patching and revert afterward).
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  CURRENT_SUB="${SUB_LEVEL:-99999}"
  if [[ "$CURRENT_SUB" =~ ^[0-9]+$ ]] && [[ "$CURRENT_SUB" -ge 92 ]]; then
    echo "Applying susfs_fake_612.py (android16-6.12 sublevel ${CURRENT_SUB})"
    python3 "$SCRIPT_DIR/susfs_fake_612.py" "$PWD/fs/proc/task_mmu.c" apply
  fi
fi

patch -p1 < "$SUSFS_PATCH" || {
  echo "::error::Failed to apply the SUSFS main patch ($SUSFS_PATCH); the kernel will lack SUSFS support" >&2
  exit 1
}

# Revert temporary layouts after patching
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  CURRENT_SUB="${SUB_LEVEL:-99999}"
  if [[ "$CURRENT_SUB" =~ ^[0-9]+$ ]] && [[ "$CURRENT_SUB" -le 30 ]]; then
    python3 "$SCRIPT_DIR/susfs_fake_66_smaps.py" "$PWD/fs/proc/task_mmu.c" revert || true
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  CURRENT_SUB="${SUB_LEVEL:-99999}"
  if [[ "$CURRENT_SUB" =~ ^[0-9]+$ ]] && [[ "$CURRENT_SUB" -ge 92 ]]; then
    python3 "$SCRIPT_DIR/susfs_fake_612.py" "$PWD/fs/proc/task_mmu.c" revert || true
  fi
fi

# 4) 5.10/5.15/6.1: the SUSFS main patch changes show_fdinfo() to three arguments, but fanotify_fdinfo()
#    still takes two, causing a link failure when CONFIG_FANOTIFY=y. Add the missing struct file *file parameter.
# Note: the script has already changed to $KERNEL_ROOT/common; use $PWD rather than $PWD/common for paths.
if [[ "$ANDROID_VERSION" == "android12" || "$ANDROID_VERSION" == "android13" ]]; then
  if [[ "$KERNEL_VERSION" == "5.10" || "$KERNEL_VERSION" == "5.15" ]]; then
    if [ -f fs/notify/fdinfo.c ]; then
      python3 "$SCRIPT_DIR/susfs_fdinfo_fanotify_arity.py" "$PWD"
    fi
  fi
fi

# 4b) All kernels: callers of the priority UID filter helpers in susfs.c are protected by #ifdef,
#     but the definitions are not; without CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER, they are unreferenced and
#     trigger clang -Werror,-Wunused-function. Guard the definitions with the same #ifdef.
# 注意：此时已 cd 到 $KERNEL_ROOT/common，路径用 $PWD/... 而非 $PWD/common/...
if [ -f fs/susfs.c ]; then
  echo "Applying susfs_guard_priority_helpers.py (guard priority UID filter helpers)"
  python3 "$SCRIPT_DIR/susfs_guard_priority_helpers.py" "$PWD/fs/susfs.c"
fi

# 4c) All kernels: Google removed #include <trace/hooks/*> from GKI source, while the SUSFS main patch
#     still references them as hunk context. Restore missing trace/hooks header context (do not change source
#     logic; restore only the include lines expected by the hunk).
python3 "$SCRIPT_DIR/susfs_restore_context.py" "$SUSFS_PATCH" "$PWD" || true

# 5) android17-6.18: upstream has no gki-android17-6.18 branch; use feat/usb-arsenal's
#    susfs618 port. Apply compilation fixes, function prototypes, and task_mmu adaptations.
# Note: the script has already changed to $KERNEL_ROOT/common; use $PWD rather than $PWD/common for paths.
if [[ "$ANDROID_VERSION" == "android17" && "$KERNEL_VERSION" == "6.18" ]]; then
  echo "Applying android17-6.18 SUSFS compatibility scripts (susfs618 port)"
  python3 "$SCRIPT_DIR/susfs_618_compile_fixes.py" "$PWD"
  python3 "$SCRIPT_DIR/susfs_618_prototypes.py" "$PWD"
  python3 "$SCRIPT_DIR/susfs_618_task_mmu.py" "$PWD"
fi

# ==================== Adaptation for the new FinaSU selinux_hide model ====================
# Starting with FinaSU v0.1.0-preview1, kernel/feature/selinux_hide.c uses the new tiann-style model:
#   remove fake_state; use backup_sepolicy + security_context_to_sid_with_policy(..., &orig_sid_p, &orig_rc_p) (8 arguments) consistently;
#   the function also performs dual-policy handling and global sidtab synchronization internally (KernelSU #3877/#3873).
# For this model, update SELinux code from the SUSFS main patch for <6.6 to use backup_sepolicy + the 8-argument _with_policy instead of &fake_state,
# and restore the permission-check order (df03912f); sidtab synchronization is built into upstream _with_policy and needs no separate backport.
NEW_MODEL=0
FINASU_SELINUX_HIDE="$KERNEL_ROOT/KernelSU/kernel/feature/selinux_hide.c"
if [ -f "$FINASU_SELINUX_HIDE" ] && ! grep -q 'fake_state' "$FINASU_SELINUX_HIDE"; then
  NEW_MODEL=1
fi
# Conditions:
#   <6.6 (5.10/5.15/6.1): the main patch modifies selinuxfs call sites / selinux_setprocattr inline and references &fake_state;
#   >=6.6 (6.6/6.12): the main patch uses backup_sepolicy + the kernel-side my_security_context_to_sid,
#   does not reference fake_state, so this branch is unnecessary (both grep conditions miss and it is skipped automatically).
# For <6.6, switch from fake_state to backup_sepolicy + the 8-argument _with_policy; otherwise the new FinaSU model has no
# fake_state definition and ThinLTO fails to link with undefined symbol: fake_state.
if [ "$NEW_MODEL" = 1 ] && [ -f security/selinux/selinuxfs.c ] \
  && { grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c \
       || grep -q '&fake_state' security/selinux/selinuxfs.c; }; then
  echo "Detected the new FinaSU selinux_hide model: switching SUSFS <6.6 SELinux code to backup_sepolicy + 8-argument _with_policy"
  python3 - <<'PYEOF'
import re as _re, sys as _sys

NEW_FS_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
    "extern int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext, u32 *scontext_len);\n"
    "extern void security_compute_av_user_with_policy(struct selinux_policy *policy, u32 ssid, u32 tsid, u16 tclass, struct av_decision *avd);\n"
)
NEW_HK_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
)

def _sub(path, name, old, new):
    s = open(path, encoding="utf-8", errors="surrogateescape").read()
    n = s.count(old)
    if n != 1:
        print("::warning::%s: %s count=%d (expect 1)" % (path, name, n))
        return
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old, new, 1))
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
_sub(fs, "extern", "extern struct selinux_state fake_state;\n", NEW_FS_EXTERNS)
_sub(fs, "ctx", "security_context_to_sid(&fake_state, buf, size, &sid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "sid2ctx", "security_sid_to_context(&fake_state, sid, &canon, &len)",
     "security_sid_to_context_with_policy(backup_sepolicy, sid, &canon, &len)")
_sub(fs, "scon", "security_context_str_to_sid(&fake_state, scon, &ssid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, scon, strlen(scon), &ssid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "tcon", "security_context_str_to_sid(&fake_state, tcon, &tsid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, tcon, strlen(tcon), &tsid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "av", "security_compute_av_user(&fake_state, ssid, tsid, tclass, &avd)",
     "security_compute_av_user_with_policy(backup_sepolicy, ssid, tsid, tclass, &avd)")

hk = "security/selinux/hooks.c"
_sub(hk, "extern", "extern struct selinux_state fake_state;\n", NEW_HK_EXTERNS)

# <6.6 form: resolve(&fake_state, value) -> _with_policy (8 arguments)
#   The 6.1 main patch uses multi-line &sid; the 5.15 main patch uses single-line &tmp_sid. Normalize both.
_hs = open(hk, encoding="utf-8", errors="surrogateescape").read()
_hs, _n = _re.subn(r"security_context_to_sid\(&fake_state, value, size,\s*\n\s*&sid, GFP_KERNEL\)",
                   "security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", _hs)
_hs, _n15 = _re.subn(r"security_context_to_sid\(&fake_state, value, size, &tmp_sid, GFP_KERNEL\)",
                     "security_context_to_sid_with_policy(backup_sepolicy, value, size, &tmp_sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", _hs)
print("%s: setprocattr.ctx <6.6=%d/%d" % (hk, _n, _n15))
open(hk, "w", encoding="utf-8", errors="surrogateescape").write(_hs)

# >=6.6 form: update existing 6-argument _with_policy declarations/calls to 8 arguments (the new model signature)
#   The 6.6 main patch includes a 6-argument extern declaration in security/selinux/{hooks,selinuxfs}.c;
#   updating only the call to 8 arguments would cause "too many arguments to function call, expected 6, have 8".
#   Therefore, update the extern declaration and call together to 8 arguments (the new FinaSU definition takes 8).
for _lab, _f in (("selinuxfs", fs), ("hooks", hk)):
    _s = open(_f, encoding="utf-8", errors="surrogateescape").read()
    # (?!, NULL, NULL) ensures idempotence: calls already changed to 8 arguments above for <6.6 are not modified again
    _s, _n2 = _re.subn(r"(security_context_to_sid_with_policy\(backup_sepolicy,[^;]*?, GFP_KERNEL)\)(?!, NULL, NULL)", r"\1, NULL, NULL)", _s)
    _s, _nd = _re.subn(r"(security_context_to_sid_with_policy\(struct selinux_policy \*policy, const char \*scontext, u32 scontext_len,\s*\n\s*u32 \*sid, u32 def_sid, gfp_t gfp_flags)\);", r"\1, u32 *orig_sid_p, int *orig_rc_p);", _s)
    open(_f, "w", encoding="utf-8", errors="surrogateescape").write(_s)
    print("%s: _with_policy 8-arg normalize=%d decl=%d" % (_lab, _n2, _nd))

_hs = open(hk, encoding="utf-8", errors="surrogateescape").read()
# The main patch has two setprocattr forms:
#   Old form (main patches before ~2026-08): defines my_setprocattr with an unconditional SETCURRENT avc_has_perm
#     — requires removing rm_early and reordering seq (df03912f);
#   Current form (main patches since 2026-10): modifies selinux_setprocattr inline using should_check_current +
#     fake_error gating — permission order already matches df03912f, and fake parsing is converted above by setprocattr.ctx
#     to use 8-argument _with_policy (with built-in sidtab sync), so rm_early/seq has no target code.
if "should_check_current" in _hs and "fake_error = security_context_to_sid_with_policy(backup_sepolicy, value, size, &tmp_sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)" in _hs:
    print("%s: Main patch uses the current gated form (should_check_current+fake_error); rm_early_setcurrent/seq do not apply, and side-channel semantics are covered" % hk)
else:
    # Remove the unconditional SETCURRENT check (df03912f): support both <6.6 (&selinux_state) and >=6.6 (no state) forms
    _removed = False
    for _rm in ("\terror = avc_has_perm(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n",
                "\terror = avc_has_perm(mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n"):
        if _hs.count(_rm) == 1:
            _hs = _hs.replace(_rm, "", 1)
            _removed = True
            print("%s: rm_early_setcurrent OK" % hk)
            break
    if not _removed:
        print("::warning::%s: rm_early_setcurrent not matched" % hk)
    # Check SETCURRENT only if backup parsing fails
    _seq_done = False
    for _old2, _new2, _lab in (
        ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error)\n\t\t\treturn error;\n",
         "\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n", "<6.6"),
        ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error)\n\t\t\treturn error;\n",
         "\t\terror = security_context_to_sid_with_policy(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n", ">=6.6")):
        if _hs.count(_old2) == 1:
            _hs = _hs.replace(_old2, _new2, 1)
            _seq_done = True
            print("%s: seq(%s) OK" % (hk, _lab))
            break
    if not _seq_done:
        print("::warning::%s: seq not matched" % hk)
open(hk, "w", encoding="utf-8", errors="surrogateescape").write(_hs)
for _f in (fs, hk):
    _s = open(_f, encoding="utf-8", errors="surrogateescape").read()
    if "fake_state" in _s:
        _sys.stderr.write("::error::%s fake_state references remain\n" % _f)
        _sys.exit(1)
PYEOF
  # Informational only: the 5.15 main patch has no perm_error (permission reordering applies only to the my_write_context form),
  # so grep may find no matches here; use || true or set -e will stop the patch step.
  grep -n 'backup_sepolicy' security/selinux/selinuxfs.c | head -3 || true
  grep -n 'perm_error' security/selinux/hooks.c | head -3 || true
fi

# ==================== Backport KernelSU SELinux hiding side-channel fix (old fake_state form)====================
# Applies only when the SUSFS main patch uses the old form (defines my_write_context/my_write_access/my_setprocattr).
# Detection checks use /sys/fs/selinux/{context,access} and setprocattr as oracles, comparing
# SIDs from the fake policy (fake_state) and global selinux_state, as well as permission-check order, to detect hiding.
# The SUSFS main patch implementations of my_write_context / my_write_access / my_setprocattr lack both:
# Add them here following KernelSU's implementation:
#   - - sidtab sync (KernelSU #3873): parse with the fake policy, then sync into the global sidtab to eliminate SID differences;
#   - - permission-check order (KernelSU df03912f): check SETCURRENT only if backup parsing fails.
# Current main patches (since 2026-10) no longer define these functions. The gated inline form for <6.6 and the NEW_MODEL branch's
# 8-argument _with_policy conversion (with built-in sidtab sync) provide equivalent side-channel fixes; see the else-branch notes below.
if [ "${NEW_MODEL:-0}" != 1 ] && [ -f security/selinux/selinuxfs.c ] && grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c \
  && [ -f security/selinux/hooks.c ] && grep -q 'static int my_setprocattr' security/selinux/hooks.c; then
  python3 - <<'PYEOF'
import re

def sed(path, name, pat, repl):
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    new, n = re.subn(pat, repl, src, count=1)
    if n == 0:
        print("::warning::%s: %s not matched (skip)" % (path, name))
        return
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(new)
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
# my_write_context (<6.6 parses with fake_state; >=6.6 uses backup_sepolicy _with_policy)
sed(fs, "ctx(<6.6)", r"(\tlength = security_context_to_sid\(&fake_state, buf, size, &sid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(&selinux_state, buf, size, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "ctx(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(buf, size, &tmp_sid, GFP_KERNEL);\n\t}\n")
# my_write_access scon / tcon
sed(fs, "scon(<6.6)", r"(\tlength = security_context_str_to_sid\(&fake_state, scon, &ssid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_str_to_sid(&selinux_state, scon, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "scon(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, scon, strlen\(scon\), &ssid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(scon, strlen(scon), &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "tcon(<6.6)", r"(\tlength = security_context_str_to_sid\(&fake_state, tcon, &tsid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_str_to_sid(&selinux_state, tcon, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "tcon(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, tcon, strlen\(tcon\), &tsid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(tcon, strlen(tcon), &tmp_sid, GFP_KERNEL);\n\t}\n")

hk = "security/selinux/hooks.c"
# Remove the unconditional SETCURRENT check (with &selinux_state before 6.6; without it on 6.6 and later).
sed(hk, "rm_early(<6.6)", r"\terror = avc_has_perm\(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL\);\n\n\tif \(error\)\n\t\treturn error;\n\n", "")
sed(hk, "rm_early(>=6.6)", r"\terror = avc_has_perm\(mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL\);\n\n\tif \(error\)\n\t\treturn error;\n\n", "")
# Check SETCURRENT only if backup parsing fails, and synchronize the global sidtab.
sed(hk, "seq+sync(<6.6)", r"(\t\terror = security_context_to_sid\(&fake_state, value, size,\n\t\t\t\t\t\t&sid, GFP_KERNEL\);\n)\t\tif \(error\)\n\t\t\treturn error;\n",
    "\\1\t\tif (error) {\n\t\t\t/* FINASU_SEQ: 仅当 backup 解析失败时才做 SETCURRENT 检查（KernelSU df03912f） */\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n\t\t{\n\t\t\tu32 tmp_sid;\n\t\t\t/* FINASU_SIDTAB_SYNC (KernelSU #3873) */\n\t\t\tsecurity_context_to_sid(&selinux_state, value, size, &tmp_sid, GFP_KERNEL);\n\t\t}\n")
sed(hk, "seq+sync(>=6.6)", r"(\t\terror = security_context_to_sid_with_policy\(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL\);\n)\t\tif \(error\)\n\t\t\treturn error;\n",
    "\\1\t\tif (error) {\n\t\t\t/* FINASU_SEQ: 仅当 backup 解析失败时才做 SETCURRENT 检查（KernelSU df03912f） */\n\t\t\tint perm_error = avc_has_perm(mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n\t\t{\n\t\t\tu32 tmp_sid;\n\t\t\t/* FINASU_SIDTAB_SYNC (KernelSU #3873) */\n\t\t\tsecurity_context_to_sid(str, size, &tmp_sid, GFP_KERNEL);\n\t\t}\n")
PYEOF
  # 仅作信息输出；旧形态模式部分失配时 grep 无命中，必须 || true，否则 pipefail 会中断整个补丁步骤
  grep -n 'FINASU_SIDTAB_SYNC' security/selinux/selinuxfs.c | head || true
  grep -n 'FINASU_SIDTAB_SYNC\|FINASU_SEQ' security/selinux/hooks.c | head || true
else
  # 主补丁形态判定：
  #   旧形态定义 my_write_context/my_write_access/my_setprocattr，缺失即异常，保留告警；
  #   现行形态（2026-10 起的主补丁）不再定义这三个函数：<6.6 内联改 selinux_setprocattr /
  #   selinuxfs 调用点（should_check_current+fake_error 门控），>=6.6 用 backup_sepolicy +
  #   my_security_context_to_sid（内核侧自含）。侧信道修复（sidtab 同步 #3873、权限顺序
  #   df03912f）由 NEW_MODEL 分支的 8 参 _with_policy 转换与门控校验覆盖，无需旧形态移植。
  if grep -qE 'static ssize_t my_write_(context|access)' security/selinux/selinuxfs.c 2>/dev/null \
    || grep -q 'static int my_setprocattr' security/selinux/hooks.c 2>/dev/null; then
    echo "::warning::未找到 SUSFS 的 my_write_context/my_setprocattr，跳过 SELinux 侧信道移植"
  else
    echo "SUSFS 主补丁为现行形态（无 my_write_context/my_setprocattr）：侧信道修复由门控校验与 8 参 _with_policy 内置同步覆盖，无需旧形态移植"
  fi
fi

# ==================== SUSFS 路径隐藏回退（跨命名空间 / FUSE） ====================
# susfs_add_sus_path（非 loop）在“调用方命名空间”里 kern_path 解析路径；管理器/ksud 常解析不到
# /storage/emulated 这类 FUSE 路径（-ENOENT），于是规则加不进去、路径隐藏失效。
# 这里加回退：解析失败时自动改走 LOOP 机制（内核 workqueue 在 init 命名空间稍后解析并打标记）。
if [ -f fs/susfs.c ] && grep -qF 'void susfs_add_sus_path(void __user **user_info)' fs/susfs.c \
  && ! grep -qF 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c; then
  python3 - <<'PYEOF'
p = "fs/susfs.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
old1 = "void susfs_add_sus_path(void __user **user_info) {"
new1 = "void susfs_add_sus_path_loop(void __user **user_info);\n" + old1
if s.count(old1) != 1:
    print("::warning::fs/susfs.c: susfs_add_sus_path 签名不是预期形态，跳过")
else:
    s = s.replace(old1, new1, 1)
    old2 = ("\tif (copy_from_user(&info, (struct st_susfs_sus_path __user*)*user_info, sizeof(info))) {\n"
            "\t\tinfo.err = -EFAULT;\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n\n"
            "\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
            "\tif (info.err) {\n"
            "\t\tSUSFS_LOGE(\"failed opening file '%s'\\n\", info.target_pathname);\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n")
    new2 = ("\tif (copy_from_user(&info, (struct st_susfs_sus_path __user*)*user_info, sizeof(info))) {\n"
            "\t\tinfo.err = -EFAULT;\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n\n"
            "\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
            "\tif (info.err) {\n"
            "\t\tSUSFS_LOGE(\"failed opening '%s' in current ns, fallback to sus_path_loop\\n\", info.target_pathname);\n"
            "\t\t/* FINASU_SUS_PATH_LOOP_FALLBACK: 调用方命名空间解析不到（常见于 /storage/emulated 等 FUSE 路径）时，\n"
            "\t\t   退回 LOOP 机制，交由内核 workqueue 在 init 命名空间稍后解析并重新打标记 */\n"
            "\t\tsusfs_add_sus_path_loop(user_info);\n"
            "\t\treturn;\n"
            "\t}\n")
    if s.count(old2) != 1:
        print("::warning::fs/susfs.c: susfs_add_sus_path 代码形态不是预期，跳过回退")
    else:
        open(p, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old2, new2, 1))
        print("fs/susfs.c: 已加 SUSFS 路径隐藏 LOOP 回退")
PYEOF
  grep -n 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c | head
else
  echo "::warning::未找到 fs/susfs.c 的 susfs_add_sus_path，跳过路径隐藏回退"
fi


# ---- 预期冲突处理：上游已包含同款修改的 .rej 剔除，真实缺失的手工补齐 ----

# 1) fs/unicode：ASB 内核已包含上游 "unicode: don't special case ignorable code
#    points" 提交，主补丁删除 ignore_init / 重生成 utf8data 的 hunk 已天然满足
if [[ -f fs/unicode/mkutf8data.c.rej ]] && ! grep -q 'ignore_init' fs/unicode/mkutf8data.c; then
  echo "fs/unicode .rej 为上游已包含同款修改，剔除预期冲突文件"
  rm -f fs/unicode/*.rej
fi

# 2) mm/rmap.c：6.6.127+ 已包含 huge_pmd_unshare 的 tlb 化改造
if [[ -f mm/rmap.c.rej ]] && grep -q 'tlb_gather_mmu_vma' mm/rmap.c; then
  echo "mm/rmap.c .rej 为上游已包含同款修改，剔除预期冲突文件"
  rm -f mm/rmap.c.rej
fi

# 3) fs/proc/task_mmu.c（6.12.69+）：show_smap 重构（vma_pages → vma_data_pages）
#    导致 SUS_MAP 检查 hunk 上下文失配被拒，属于真实缺失，手工补回
if [[ -f fs/proc/task_mmu.c.rej ]] \
  && grep -qF 'static int show_smap(struct seq_file *m, void *v)' fs/proc/task_mmu.c; then
  SHOW_SMAP_BODY="$(sed -n '/^static int show_smap(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c)"
  if [[ -n "$SHOW_SMAP_BODY" ]] && ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' <<< "$SHOW_SMAP_BODY"; then
    echo "为 show_smap 手工补入 SUS_MAP 检查（6.12.69+ 上下文漂移）"
    perl -0pi -e 's/(static int show_smap\(struct seq_file \*m, void \*v\)\n\{\n\tstruct vm_area_struct \*vma = v;\n\tstruct mem_size_stats mss = \{\};\n)/$1\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (vma->vm_file) {\n\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\treturn 0;\n\t}\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n/' fs/proc/task_mmu.c
    if ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' fs/proc/task_mmu.c; then
      echo "::error::show_smap SUS_MAP 检查手工补丁失败，请人工核对 fs/proc/task_mmu.c"
      exit 1
    fi
  fi

  # 同一个文件在 6.12.69+ 还把 show_smaps_rollup 重写成 VMA_ITERATOR + for_each_vma
  # （删掉了 out_unlock 分支），主补丁那两段 hunk 依赖旧上下文全部被拒；虽然不影响
  # 编译，但 SUS_MAP 标记的 VMA 会经 /proc/<pid>/smaps_rollup 泄露。这里在 do 循环
  # 入口整段跳过该 VMA，并同步 last_vma_end，语义与主补丁的 bypass_orig_flow 一致。
  if grep -qF 'bypass_orig_flow' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    echo "为 show_smaps_rollup 手工补入 SUS_MAP 跳过逻辑（6.12.69+ 上下文漂移）"
    python3 - <<'PYEOF'
p = "fs/proc/task_mmu.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
start = s.find("static int show_smaps_rollup(struct seq_file *m, void *v)")
end = s.find("\n}\n", start)
if start < 0 or end < 0:
    print("::error::fs/proc/task_mmu.c: 未找到 show_smaps_rollup")
    raise SystemExit(1)
body = s[start:end]
needle = "\tdo {\n\t\tsmap_gather_stats(vma, &mss, 0);\n"
insert = (
    "\tdo {\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\t/* SUS_MAP 标记的 VMA 整体跳过，避免 rollup 中泄露 */\n"
    "\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))) {\n"
    "\t\t\tlast_vma_end = vma->vm_end;\n"
    "\t\t\tcontinue;\n"
    "\t\t}\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tsmap_gather_stats(vma, &mss, 0);\n"
)
if "SUSFS_IS_INODE_SUS_MAP" in body:
    print("show_smaps_rollup 已含 SUS_MAP 检查，跳过")
elif body.count(needle) != 1:
    print("::error::show_smaps_rollup 循环入口形态不是预期，跳过")
    raise SystemExit(1)
else:
    s = s[:start] + body.replace(needle, insert, 1) + s[end:]
    open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("show_smaps_rollup: 已补入 SUS_MAP 跳过逻辑")
PYEOF
    if ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
      echo "::error::show_smaps_rollup SUS_MAP 跳过逻辑手工补丁失败，请人工核对 fs/proc/task_mmu.c"
      exit 1
    fi
  fi

  # 拒绝内容已全部补齐，删除 .rej，避免继续污染 Rejects 产物
  TASK_MMU_UNRESOLVED=0
  if grep -qF 'bypass_orig_flow' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    TASK_MMU_UNRESOLVED=1
  fi
  if grep -qF 'static int show_smap(struct seq_file *m, void *v)' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smap(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    TASK_MMU_UNRESOLVED=1
  fi
  if [[ "$TASK_MMU_UNRESOLVED" -eq 0 ]]; then
    # 仅当拒绝内容全部落在已处理的两个函数上时才删除，避免掩盖新出现的漂移
    UNKNOWN_HUNK="$(grep '^@@' fs/proc/task_mmu.c.rej | grep -vE 'show_smap|show_smaps_rollup' || true)"
    if [[ -z "$UNKNOWN_HUNK" ]]; then
      echo "fs/proc/task_mmu.c 拒绝内容已全部补齐，剔除 .rej"
      rm -f fs/proc/task_mmu.c.rej
    else
      echo "::warning title=task_mmu 冲突::仍有未识别的 hunk，保留 .rej 供排查："
      echo "$UNKNOWN_HUNK"
    fi
  fi
fi

# 上游 5.10 主补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# fs/statfs.c 的使用点之后（vfs_statfs 之前），clang -Werror 报隐式声明；
# 声明属于 SUSFS 接口，直接补进公共头 include/linux/susfs_def.h：
# 不依赖 statfs.c 内锚点与行号比较，声明重复合法，上游后续自行修复也不冲突。
# 注意：FinaSU 的 setuid_hook.c / sucompat.c 会在仅有 <linux/types.h> 等基础
# 头文件时就包含 susfs_def.h，此时 struct kstatfs 尚未声明，原型内引入新
# struct 标签会触发 clang -Werror,-Wvisibility（上游内核构建日志实证），
# 因此必须连同 struct 前置声明一起插入。
SUSFS_DEF_H="$KERNEL_ROOT/common/include/linux/susfs_def.h"
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c \
  && [[ -f "$SUSFS_DEF_H" ]] \
  && ! grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' "$SUSFS_DEF_H"; then
  echo "将 susfs_sus_kstat_spoof_vfs_statfs 声明补入 include/linux/susfs_def.h"
  sed -i '/^#endif \/\/ #ifndef KSU_SUSFS_DEF_H$/i struct inode;\nstruct kstatfs;\nextern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' "$SUSFS_DEF_H"
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件，上游自带的已提交 .rej 不计入
mapfile -t SUSFS_REJ_FILES < <(list_untracked_rej)
SUSFS_REJ_COUNT=${#SUSFS_REJ_FILES[@]}
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  printf '%s\n' "${SUSFS_REJ_FILES[@]}"
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.10" && "$CURRENT_SUB" -le 107 ]]; then
  echo "还原 Android 13 5.10 fdinfo.c 临时调整"
  restore_legacy_fdinfo_context
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "还原 Android 13 5.15 LTS 头文件上下文"
    if ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

fix_missing_vm_flags_clear() {
  # Google 2024-11 及更新的 deprecated 分支带入了 16KB 页迁移的 VMA padding：
  # mm/mmap.c 的 copy_vma() 调用 vm_flags_clear()，但同分支 include/linux 未
  # 提供该（6.3+ 才引入的）helper，clang -Werror 报隐式声明中断编译。
  # 按源码内容检测：helper 齐备（6.6+ 原生）或无调用时自动跳过，
  # 不再按 OS_PATCH_LEVEL 猜测命中范围（android13-5.10 / android14-5.15 的
  # 2024-11 分支与 android12-5.10 / android13-5.15 同样命中）。
  if grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c \
    && ! grep -Rqs 'vm_flags_clear' ./include/linux; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
    echo "已替换 mm/mmap.c 缺失 helper 的 vm_flags_clear 调用（VMA padding 半回移兼容）"
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# mmap.c 的 vm_flags_clear 半回移修复对所有内核统一按内容检测（函数内部自带
# 守卫，helper 齐备或无调用时为空操作），覆盖各 android 版本 2024-11 起
# 持续更新的 deprecated 分支
fix_missing_vm_flags_clear

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

# Android 16 - 6.12 修复
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # SukiSU（LEGACY_SUKISU_CONFIG）与原生 KernelSU（CONFIG_KSU_MANUAL_HOOK）在 6.12 上
  # 都会与 SUSFS 重复定义 setresuid hook，导致重复定义错误。
  # 修复：当 SUSFS 启用时（CONFIG_KSU_SUSFS=y），跳过 KSU 侧的 setresuid hook 定义。
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -f "$SETUID_HOOK" ]] \
    && { [[ -n "$LEGACY_SUKISU_CONFIG" ]] || [[ "$KSU_VARIANT" == "KernelSU" ]]; } \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "已修复 setuid_hook.c 重复定义问题（KSU 变体: ${KSU_VARIANT:-未知}）"
  fi
fi

# 守护：主补丁若再次因上下文漂移漏掉 susfs_def.h，在这里给出可读错误，
# 而不是等到编译 fs/proc/task_mmu.c 时才报一串 SUSFS_IS_INODE_* 隐式声明
for SUSFS_SRC in fs/proc/task_mmu.c fs/namespace.c; do
  [[ -f "$SUSFS_SRC" ]] || continue
  if grep -qE 'SUSFS_IS_INODE_|CL_COPY_MNT_NS' "$SUSFS_SRC" \
    && ! grep -qF '#include <linux/susfs_def.h>' "$SUSFS_SRC"; then
    echo "::error::$SUSFS_SRC 使用了 SUSFS 宏但缺少 linux/susfs_def.h，主补丁 hunk 未应用"
    exit 1
  fi
done
