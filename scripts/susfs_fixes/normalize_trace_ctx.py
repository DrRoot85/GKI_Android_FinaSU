#!/usr/bin/env python3
# Normalize trace/hooks context in the SUSFS main patch hunk that inserts susfs_def.h
#
# Background:
#   On 2026-10-18, SUSFS upstream rebased the gki-android13-5.15 main patch onto 5.15.211,
#   so the first hunks in fs/proc/task_mmu.c and fs/namespace.c now use
#   `#include <trace/hooks/mm.h>` / `#include <trace/hooks/blk.h>` as context.
#   - GKI source for 5.15.74–5.15.194 lacks these lines, so the entire hunk is rejected ->
#     susfs_def.h is not included -> SUSFS_IS_INODE_* is implicitly declared -> clang -Werror stops compilation;
#   - 5.15.220 (LTS) includes these lines, but the old script removed them to match the pre-rebase patch,
#     which also caused the entire hunk to be rejected.
#
# Strategy:
#   Process only hunks whose patch body contains susfs_def.h. If a trace/hooks context line in the hunk
#   does not exist near the top of the target file, remove it from the patch copy and recalculate the hunk line counts. The source
#   itself is never changed. Leave the patch unchanged when the target file contains the line.
import re
import sys

HUNK_HDR = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
TRACE_PREFIX = '#include <trace/hooks/'
HEAD_LIMIT = 200


def read_head(path):
    """Return the first HEAD_LIMIT stripped lines of the target file, or None if it does not exist."""
    try:
        with open(path, encoding='utf-8', errors='surrogateescape') as f:
            head = []
            for _ in range(HEAD_LIMIT):
                line = f.readline()
                if not line:
                    break
                head.append(line.strip())
            return head
    except OSError:
        return None


def normalize(patch_path):
    with open(patch_path, encoding='utf-8', errors='surrogateescape') as f:
        lines = f.read().splitlines()

    out = []
    touched = set()
    dropped = 0
    cur_file = None
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith('+++ b/'):
            cur_file = line[6:].split('\t')[0].strip()
            out.append(line)
            i += 1
            continue

        m = HUNK_HDR.match(line)
        if not m:
            out.append(line)
            i += 1
            continue

        j = i + 1
        body = []
        while j < len(lines) and not lines[j].startswith(('@@', 'diff --git')):
            body.append(lines[j])
            j += 1

        if cur_file and any('susfs_def.h' in l for l in body):
            head = read_head(cur_file)
            if head is not None:
                kept = []
                for l in body:
                    ctx = l[1:].strip()
                    if l[:1] == ' ' and ctx.startswith(TRACE_PREFIX) and ctx not in head:
                        dropped += 1
                        continue
                    kept.append(l)
                if len(kept) != len(body):
                    old_count = sum(1 for l in kept if l[:1] in (' ', '-'))
                    new_count = sum(1 for l in kept if l[:1] in (' ', '+'))
                    line = '@@ -%s,%d +%s,%d @@' % (m.group(1), old_count, m.group(3), new_count)
                    body = kept
                    touched.add(cur_file)

        out.append(line)
        out.extend(body)
        i = j

    if dropped:
        with open(patch_path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n') as f:
            f.write('\n'.join(out) + '\n')
        print('SUSFS patch context normalized for %s: removed %d missing trace/hooks context line(s)'
              % (', '.join(sorted(touched)), dropped))
    else:
        print('SUSFS header context does not need normalization')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: normalize_trace_ctx.py <patch>', file=sys.stderr)
        sys.exit(2)
    normalize(sys.argv[1])
