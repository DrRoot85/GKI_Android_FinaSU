#!/usr/bin/env bash
# Dynamically sync the SukiSU-Nova builtin kernel UAPI with the official main-branch manager.
#
# Background:
#   The builtin branch (built-in + SUSFS product line) is independent of the official main
#   branch, while the official manager APK is always built from main. When main raises
#   KERNEL_SU_UAPI_VERSION in uapi/supercall.h (for example, commit 3b60791 raised UAPI to 6
#   and added KSU_IOCTL_LOOKUP_SYMBOLS / KSU_GET_INFO_FLAG_PREINIT), the builtin kernel UAPI
#   can lag behind the manager. The manager then sets requiresNewKernel = true and shows
#   "Kernel update required" on its home screen (Natives.kt: managerUAPIVersion > kernelUAPIVersion).
#
# This script dynamically ports the missing UAPI constant declarations, KSU_GET_INFO_FLAG_*
#   bits, new ioctl constants, and struct ksu_lookup_symbols_cmd from the official main
#   uapi/supercall.h into the builtin header, preserving the upstream text and raising the
#   UAPI version to match main. build.yml injects the related kernel-side support (the
#   LOOKUP_SYMBOLS handler and symbol_resolver) in a separate content-checked step afterward.
#
# All ports use content checks: existing content is skipped, repeated runs are idempotent,
#   and the script also skips automatically once upstream syncs the builtin UAPI.
#
# Usage: sync_uapi.sh [KernelSU directory] (run from $KERNEL_ROOT; access to the official
#       repository at raw.githubusercontent.com is required).

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=SukiSU-Nova UAPI sync skipped::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU-Nova UAPI sync** skipped automatically: $1 (build continues)" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

[ -d "$KSU_DIR" ] || fail "KernelSU directory not found: $KSU_DIR"

COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# builtin branch: kernel/include/uapi/supercall.h; main branch: uapi/supercall.h
UAPI_FILE=""
for f in "$KSU_DIR/kernel/include/uapi/supercall.h" "$KSU_DIR/uapi/supercall.h"; do
  if [ -f "$f" ]; then
    UAPI_FILE="$f"
    break
  fi
done
[ -n "$UAPI_FILE" ] || fail "supercall.h not found; the SukiSU-Nova source layout may have changed"

read_uapi() {
  grep -ohE 'KERNEL_SU_UAPI_VERSION[^0-9]*[0-9]+' "$1" | grep -oE '[0-9]+' | tail -n 1
}

# Fetch the official main supercall.h (web layout; UAPI definitions are published as static const).
MAIN_URL="https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/main/uapi/supercall.h"
MAIN_FILE=$(mktemp)
MAIN_JSON=""
for ATTEMPT in 1 2 3; do
  if curl -sL --fail --max-time 60 -o "$MAIN_FILE" "$MAIN_URL" && [ -s "$MAIN_FILE" ]; then
    break
  fi
  echo "Failed to fetch the official main supercall.h; retrying ($ATTEMPT/3)..."
  sleep 5
done
[ -s "$MAIN_FILE" ] || fail "Could not fetch the official main uapi/supercall.h; aborting UAPI sync"

MAIN_UAPI=$(read_uapi "$MAIN_FILE")
CUR_UAPI=$(read_uapi "$UAPI_FILE")
echo "Official main UAPI version: ${MAIN_UAPI:-unknown}; current builtin checkout UAPI version: ${CUR_UAPI:-unknown}"
[ -n "$MAIN_UAPI" ] || fail "Could not parse KERNEL_SU_UAPI_VERSION from the official main supercall.h"

if [ "${CUR_UAPI:-0}" -ge "$MAIN_UAPI" ]; then
  echo "Builtin checkout UAPI >= official main ($CUR_UAPI >= $MAIN_UAPI); sync is unnecessary, skipping"
  rm -f "$MAIN_FILE"
  exit 0
fi

python3 - "$UAPI_FILE" "$MAIN_FILE" <<'PYEOF'
import sys, re

uapi_path, main_path = sys.argv[1], sys.argv[2]
uapi = open(uapi_path, encoding="utf-8", errors="surrogateescape").read()
main = open(main_path, encoding="utf-8", errors="surrogateescape").read()

def read_num(text, name):
    m = re.search(re.escape(name) + r"[^0-9]*(\d+)", text)
    return int(m.group(1)) if m else None

main_ver = read_num(main, "KERNEL_SU_UAPI_VERSION")
cur_ver = read_num(uapi, "KERNEL_SU_UAPI_VERSION")
if not main_ver:
    print("::error::Official main supercall.h is missing KERNEL_SU_UAPI_VERSION")
    sys.exit(1)

changed = []

# 1) Port missing constants using the official values, including the raised
#    KERNEL_SU_UAPI_VERSION, EVENT_*, KSU_GET_INFO_FLAG_* bits, new ioctl constants,
#    and KSU_LOOKUP_SYMBOLS_MAX. Preserve the builtin DECLARE macro style (outside
#    BINDGEN it expands to an enum, providing compile-time constants required by
#    dispatch.c's static handler table; main's static const form would fail in the
#    builtin static-initializer context with "initializer element is not a compile-time constant").
#    Port constants individually rather than replacing the entire file: the builtin header
#    has independently evolved content (DECLARE macros, __user annotations on ksu_kpm_cmd,
#    etc.) that would be overwritten by a full replacement.
def parse_decls(text):
    decls = {}
    for m in re.finditer(r"^static const (\w[\w\s\*]*?)\b(\w+)\s*=\s*([^;\n]+);", text, re.M):
        decls.setdefault(m.group(2), (m.group(1), m.group(3)))
    return decls

main_decls = parse_decls(main)
has_declare = "#define DECLARE" in uapi

# 2) Port struct definitions missing from builtin (such as ksu_lookup_symbols_cmd /
#    ksu_set_spoof_version_cmd). Define structs before the _IOW constants that use them,
#    and insert them inside the include guard (supercall.h is included multiple times by
#    ksu.c / dynamic_manager.c; content after the final #endif would be redefined on each include).
struct_re = re.compile(r"^struct (\w+) \{(?:[^{}])*?\};", re.M | re.S)
main_structs = []
for m in struct_re.finditer(main):
    main_structs.append((m.group(1), m.group(0)))

missing_structs = [(n, t) for n, t in main_structs if not re.search(r"struct\s+" + re.escape(n) + r"\s*\{", uapi)]
missing_decls = {n: v for n, v in main_decls.items() if not re.search(r"\b" + re.escape(n) + r"\b", uapi)}

# Shared insertion point: after the flag block (inside the guard, after DECLARE macros, before struct/constant use).
anchor = re.search(r"(DECLARE\(__u32, KSU_GET_INFO_FLAG_PR_BUILD[^\n]*\n|static const __u32 KSU_GET_INFO_FLAG_PR_BUILD[^\n]*\n)", uapi)
if not anchor:
    anchor = re.search(r"(DECLARE\(__u32, KERNEL_SU_UAPI_VERSION[^\n]*\n|static const __u32 KERNEL_SU_UAPI_VERSION[^\n]*\n)", uapi)
if not anchor:
    print("::error::Builtin supercall.h is missing the constant/struct insertion anchor (UAPI/FLAG block)")
    sys.exit(1)
pos = anchor.end()

block = "\n// synced from SukiSU-Nova main uapi/supercall.h (dynamic UAPI sync)\n"
# Insert structs first; same-name _IOW constants in the insertion block may reference them.
for sname, text in missing_structs:
    block += text + "\n"
    changed.append("struct " + sname)
for name, (ctype, value) in missing_decls.items():
    if has_declare:
        block += "DECLARE(%s, %s, %s);\n" % (ctype, name, value)
    else:
        block += "static const %s %s = %s;\n" % (ctype, name, value)
    changed.append(name)
if missing_decls:
    block += "\n"

uapi = uapi[:pos] + block + uapi[pos:]

# 3) Raise the UAPI version to the official value.
if cur_ver is not None and cur_ver < main_ver:
    uapi = re.sub(
        r"((?:DECLARE\(__u32, KERNEL_SU_UAPI_VERSION|static const __u32 KERNEL_SU_UAPI_VERSION)[^\n]*?)\b%d\b" % cur_ver,
        r"\g<1>%d" % main_ver,
        uapi, count=1)
    changed.append("KERNEL_SU_UAPI_VERSION %d -> %d" % (cur_ver, main_ver))

if not changed:
    print("supercall.h: nothing to port (UAPI version and constants are already present)")
else:
    open(uapi_path, "w", encoding="utf-8", errors="surrogateescape").write(uapi)
    for c in changed:
        print("supercall.h: ported %s" % c)
PYEOF

# ---------------- Kernel-side support injection (LOOKUP_SYMBOLS / symbol_resolver) ----------------
# For UAPI >= 6, the manager probes KSU_IOCTL_LOOKUP_SYMBOLS for hot-loaded module symbol binding.
# This requires main's infra/symbol_resolver, which is missing from the builtin checkout. Use
# content checks to inject it: copy the resolver sources, add kernel includes, and wire up
# do_lookup_symbols.
if grep -q 'KSU_IOCTL_LOOKUP_SYMBOLS' "$UAPI_FILE" 2>/dev/null; then
  RESOLVER_C="$KSU_DIR/kernel/infra/symbol_resolver.c"
  RESOLVER_H="$KSU_DIR/kernel/infra/symbol_resolver.h"
  if [ ! -f "$RESOLVER_C" ] || ! grep -q 'ksu_lookup_kernel_symbols' "$RESOLVER_C" 2>/dev/null; then
    echo "Injecting infra/symbol_resolver (main-branch UAPI 6 bulk symbol resolution)..."
    cp "$COMPAT_DIR/symbol_resolver.h" "$RESOLVER_H" || fail "failed to copy symbol_resolver.h"
    cp "$COMPAT_DIR/symbol_resolver.c" "$RESOLVER_C" || fail "failed to copy symbol_resolver.c"
    grep -q 'ksu_lookup_kernel_symbols' "$RESOLVER_C" || fail "validation failed after copying symbol_resolver.c"
  else
    echo "infra/symbol_resolver already exists; skipping copy"
  fi

  # builtin uses a ksu.c unity build (kernel_includes.h aggregates kernel headers),
  # but lacks the bsearch/sort/kallsyms headers required by the resolver; add them as needed.
  KINC="$KSU_DIR/kernel/kernel_includes.h"
  if [ -f "$KINC" ] && [ -f "$RESOLVER_C" ]; then
    for HDR in bsearch sort kallsyms; do
      if grep -q "ksu_lookup_kernel_symbols" "$RESOLVER_C" && ! grep -q "include <linux/$HDR.h>" "$KINC"; then
        sed -i "s|^#include <linux/kernel.h>|#include <linux/kernel.h>\n#include <linux/$HDR.h>|" "$KINC" \
          || fail "failed to add <linux/$HDR.h> to kernel_includes.h"
        grep -q "include <linux/$HDR.h>" "$KINC" || fail "kernel_includes.h validation failed for <linux/$HDR.h>"
        echo "kernel_includes.h: added <linux/$HDR.h>"
      fi
    done
  fi

  # Wire up the include, handler, and ioctl table entry (builtin dispatch.c has no includes; unity build).
  DISPATCH="$KSU_DIR/kernel/supercall/dispatch.c"
  if [ -f "$DISPATCH" ] && [ -f "$RESOLVER_C" ]; then
    if ! grep -q 'do_lookup_symbols' "$DISPATCH"; then
      echo "Wiring the do_lookup_symbols handler into supercall/dispatch.c..."
      python3 - "$DISPATCH" "$UAPI_FILE" <<'PYEOF2'
import sys, re

path = sys.argv[1]
s = open(path, encoding="utf-8", errors="surrogateescape").read()

# 1) Declare the resolver before including its source in the unity build.
if '#include "infra/symbol_resolver.h"' not in s and '#include "infra/symbol_resolver.c"' not in s:
    # dispatch.c has no include section; use an extern declaration instead.
    s = ("extern int ksu_lookup_kernel_symbols(const char *const *names, unsigned long *addrs, u32 count);\n\n" + s)

# 2) do_lookup_symbols handler: insert before the do_disable_escape_to_root definition.
handler = '''/*
 * Batch resolve kernel image symbols (exported or not) for userspace
 * module symbol binding, ported from SukiSU-Nova main (UAPI 6).
 */
static int do_lookup_symbols(void __user *arg)
{
    struct ksu_lookup_symbols_cmd cmd;
    const u64 __user *unames;
    u64 __user *uaddrs;
    char **names;
    unsigned long *addrs;
    int ret = 0;
    u32 i;

    if (copy_from_user(&cmd, arg, sizeof(cmd)))
        return -EFAULT;

    if (cmd.flags) {
        pr_err("lookup_symbols: unsupported flags 0x%x\\n", cmd.flags);
        return -EINVAL;
    }
    if (!cmd.count || cmd.count > KSU_LOOKUP_SYMBOLS_MAX)
        return -EINVAL;

    names = kvcalloc(cmd.count, sizeof(*names), GFP_KERNEL);
    addrs = kvcalloc(cmd.count, sizeof(*addrs), GFP_KERNEL);
    if (!names || !addrs) {
        ret = -ENOMEM;
        goto out;
    }

    unames = (const u64 __user *)(uintptr_t)cmd.names;
    uaddrs = (u64 __user *)(uintptr_t)cmd.addrs;
    for (i = 0; i < cmd.count; i++) {
        u64 uname;
        char *name;

        if (get_user(uname, unames + i)) {
            ret = -EFAULT;
            goto out;
        }
        name = strndup_user((const char __user *)(uintptr_t)uname, KSYM_NAME_LEN);
        if (IS_ERR(name)) {
            // An overlong name cannot be a kernel symbol: report it missing.
            if (PTR_ERR(name) == -EINVAL)
                continue;
            ret = PTR_ERR(name);
            goto out;
        }
        if (!*name) {
            kfree(name);
            continue;
        }
        names[i] = name;
    }

    ret = ksu_lookup_kernel_symbols((const char *const *)names, addrs, cmd.count);
    if (ret < 0)
        goto out;

    for (i = 0; i < cmd.count; i++) {
        if (put_user((u64)addrs[i], uaddrs + i)) {
            ret = -EFAULT;
            goto out;
        }
    }

out:
    if (names) {
        for (i = 0; i < cmd.count; i++)
            kfree(names[i]);
    }
    kvfree(names);
    kvfree(addrs);
    return ret;
}

'''
anchor = "static int do_disable_escape_to_root(void __user *arg)"
if anchor not in s:
    print("::error::dispatch.c is missing the do_disable_escape_to_root anchor; cannot insert do_lookup_symbols")
    sys.exit(1)
s = s.replace(anchor, handler + anchor, 1)

# 3) ioctl table entry: insert after DISABLE_ESCAPE_TO_ROOT, when LOOKUP_SYMBOLS is available.
entry = '''    {
        .cmd = KSU_IOCTL_LOOKUP_SYMBOLS,
        .name = "LOOKUP_SYMBOLS",
        .handler = do_lookup_symbols,
        .perm_check = only_root
    },
'''
anchor2 = re.search(r"\.cmd = KSU_IOCTL_DISABLE_ESCAPE_TO_ROOT,(?:.*\n)*?    \},\n", s)
if not anchor2:
    print("::error::dispatch.c handler table is missing the DISABLE_ESCAPE_TO_ROOT anchor")
    sys.exit(1)
s = s[:anchor2.end()] + entry + s[anchor2.end():]

open(path, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("dispatch.c: wired the do_lookup_symbols handler and LOOKUP_SYMBOLS table entry")
PYEOF2
      grep -q 'do_lookup_symbols' "$DISPATCH" || fail "dispatch.c validation failed after wiring"
    else
      echo "dispatch.c already contains do_lookup_symbols; skipping wiring"
    fi

    # builtin uses a ksu.c unity build (all .c files are aggregated into ksu.o via #include),
    # so the resolver source must be included in ksu.c or linking will fail with an undefined symbol.
    KSU_C="$KSU_DIR/kernel/ksu.c"
    if [ -f "$KSU_C" ] && ! grep -q '#include "infra/symbol_resolver.c"' "$KSU_C"; then
      sed -i 's|^#include "infra/event_queue.c"|#include "infra/event_queue.c"\n#include "infra/symbol_resolver.c"|' "$KSU_C" \
        || fail "failed to include symbol_resolver.c in ksu.c"
      grep -q '#include "infra/symbol_resolver.c"' "$KSU_C" || fail "ksu.c symbol_resolver.c include validation failed"
      echo "ksu.c: added #include infra/symbol_resolver.c (unity build)"
    elif [ -f "$KSU_C" ]; then
      echo "ksu.c already includes symbol_resolver.c; skipping"
    fi

    # Initialization wiring: initialize the resolver function-pointer table in kernelsu_init.
    if ! grep -q 'ksu_init_symbol_resolver' "$KSU_C" 2>/dev/null; then
      python3 - "$KSU_C" <<'PYEOF3'
import sys, re
path = sys.argv[1]
s = open(path, encoding="utf-8", errors="surrogateescape").read()
if "ksu_init_symbol_resolver();" not in s:
    anchor = "    ksu_supercalls_init();"
    if anchor in s:
        s = s.replace(anchor, anchor + "\n\n    ksu_init_symbol_resolver();", 1)
        open(path, "w", encoding="utf-8", errors="surrogateescape").write(s)
        print("ksu.c: wired ksu_init_symbol_resolver() into kernelsu_init")
    else:
        print("::warning::ksu.c is missing the ksu_supercalls_init anchor; resolver initialization was not wired (LOOKUP_SYMBOLS will fall back to an uninitialized walker)")
else:
    print("ksu.c already calls ksu_init_symbol_resolver(); skipping")
PYEOF3
    else
      echo "ksu.c already calls ksu_init_symbol_resolver(); skipping"
    fi
  fi
else
  echo "UAPI < 6 has no LOOKUP_SYMBOLS; skipping kernel-side support injection"
fi

FINAL_UAPI=$(read_uapi "$UAPI_FILE")
[ "${FINAL_UAPI:-0}" -eq "$MAIN_UAPI" ] || fail "UAPI version validation failed (expected $MAIN_UAPI, got ${FINAL_UAPI:-unknown})"
echo "UAPI sync complete: builtin checkout UAPI $CUR_UAPI -> $FINAL_UAPI (official main $MAIN_UAPI)"
rm -f "$MAIN_FILE"
