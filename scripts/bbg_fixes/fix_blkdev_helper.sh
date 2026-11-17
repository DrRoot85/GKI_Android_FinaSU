#!/usr/bin/env bash
# Fix build failures in Baseband-guard blkdev_helper.c on Linux 6.9+.
#
# Background: upstream commit 1c66495 added calls to blkdev_get_no_open() and
# blkdev_put_no_open() in is_allowed_partition_dev_resolve(), but includes only
# <linux/blkdev.h>. This API is declared in include/linux/blkdev.h on 5.11-6.8
# (single-argument blkdev_get_no_open(dev)); from 6.9 it moved to the private
# block/blk.h header, and from 6.15 its signature takes two arguments:
# blkdev_get_no_open(dev, bool autoload). On 6.9+, the declaration is not visible,
# so clang -Werror reports an implicit function declaration and int-to-pointer error.
# (The upstream CI main branch also fails on android17-6.18, with no fix yet;
# baseband_guard.c and tracing.c are unaffected because kernel_compat.h includes "blk.h".)
#
# Fix: inspect the actual kernel headers. If the declaration has moved to block/blk.h,
# add #include "blk.h" (the BBG Makefile already passes -I$(srctree)/block) and adapt
# the call to the signature present in that header. Leave versions where the declaration
# remains in the public header (<=6.8 and backport branches) unchanged.
#
# Usage: fix_blkdev_helper.sh <kernel source root> (e.g. common/; defaults to common/).
set -eo pipefail

KERNEL_SRC="${1:-common}"
BBG_C="$KERNEL_SRC/security/baseband-guard/blkdev_helper.c"

if [ ! -f "$BBG_C" ]; then
  # Versions without BBG do not have this file; skip normally and log without an annotation.
  echo "BBG blkdev_helper.c not found ($BBG_C); skipping patch"
  exit 0
fi

if ! grep -q 'blkdev_get_no_open' "$BBG_C"; then
  echo "BBG blkdev_helper.c does not need a patch (no blkdev_get_no_open call)"
  exit 0
fi

if grep -q 'BBG_BLKDEV_COMPAT_DONE' "$BBG_C"; then
  echo "BBG blkdev_helper.c is already patched; skipping"
  exit 0
fi

# The declaration remains in the public include/linux/blkdev.h header (<=6.8 and some backport branches); no change is needed.
if grep -q 'blkdev_get_no_open' "$KERNEL_SRC/include/linux/blkdev.h" 2>/dev/null; then
  echo "BBG blkdev_helper.c does not need a patch (blkdev_get_no_open is declared in the public header)"
  exit 0
fi

# 6.9+: the declaration moved to the private block/blk.h header; 6.15+ adds bool autoload to the signature.
if grep -q 'blkdev_get_no_open(dev_t dev, bool' "$KERNEL_SRC/block/blk.h" 2>/dev/null; then
  NEW_CALL='bdev = blkdev_get_no_open(dev, true);'
elif grep -q 'blkdev_get_no_open(dev_t dev)' "$KERNEL_SRC/block/blk.h" 2>/dev/null; then
  NEW_CALL='bdev = blkdev_get_no_open(dev);'
else
  # Older versions such as 5.10 do not have this API; skip normally and log without an annotation.
  echo "No blkdev_get_no_open declaration in block/blk.h; skipping automatic adaptation (the upstream BBG layout may have changed)"
  exit 0
fi

echo "BBG: blkdev_get_no_open is declared in block/blk.h; adding the include and adapting the call signature"

if ! grep -q '#include "blk.h"' "$BBG_C"; then
  sed -i 's|#include <linux/blkdev.h>|#include <linux/blkdev.h>\n#include "blk.h"|' "$BBG_C"
fi
sed -i "s|bdev = blkdev_get_no_open(dev);|$NEW_CALL|" "$BBG_C"
sed -i '1i /* BBG_BLKDEV_COMPAT_DONE */' "$BBG_C"

echo "BBG blkdev_helper.c compatibility patch complete"
