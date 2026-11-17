#!/usr/bin/env python3
"""Completely remove kmi_symbol_list_strict_mode from common/BUILD.bazel.

This property appears in three forms across GKI branches:
  * Single-line rule property: kmi_symbol_list_strict_mode = True/False,
  * target_configs dictionary entry: "kmi_symbol_list_strict_mode": True/False,
  * Multi-line select({...}) block (android17-6.18, selected by page_size)

The previous `sed '/kmi_symbol_list_strict_mode/d'` command removed only the first
line of a select block, leaving orphaned dictionary literals and causing a BUILD.bazel
syntax error (Bazel parsing fails and all targets in the package become invisible).
This script matches each form and removes the entire property, entry, or block.
"""

import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: %s BUILD.bazel" % sys.argv[0], file=sys.stderr)
        return 2

    path = sys.argv[1]
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    total = src.count("kmi_symbol_list_strict_mode")

    # Single-line rule property (kernel_build/common_kernel call).
    src = re.sub(
        r"^[ \t]*kmi_symbol_list_strict_mode[ \t]*=[ \t]*(?:True|False),[ \t]*\n",
        "",
        src,
        flags=re.M,
    )
    # target_configs dictionary entry.
    src = re.sub(
        r'^[ \t]*"kmi_symbol_list_strict_mode"[ \t]*:[ \t]*(?:True|False),[ \t]*\n',
        "",
        src,
        flags=re.M,
    )
    # Multi-line select({...}) block: the dictionary body contains only flat "label": value lines;
    # the first "})," marks the end of the block.
    src = re.sub(
        r"^[ \t]*kmi_symbol_list_strict_mode[ \t]*=[ \t]*select\(\{.*?\}\),[ \t]*\n",
        "",
        src,
        flags=re.M | re.S,
    )

    removed = total - src.count("kmi_symbol_list_strict_mode")
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src)
    print("BUILD.bazel: removed %d occurrence(s) of kmi_symbol_list_strict_mode" % removed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
