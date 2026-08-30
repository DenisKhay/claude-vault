#!/usr/bin/env python3
"""Render a SessionStart context block as hook JSON on stdout, size-guarded.

Reads the assembled block on STDIN (never argv — a single argv string is capped at
MAX_ARG_STRLEN, 128 KiB, and passing the block to `jq --arg` blew that ceiling on a
real vault: one subgraph's Entry-nodes list had grown to 110 KiB, the hook died with
"Argument list too long" and every session started with NO vault context at all).

Two guards, both on the bullet lines only — headers, entry paths and the retrieval
trailer always survive, so a truncated block still tells the model how to search:
  VAULT_MAX_BULLET_CHARS  per-bullet clamp   (default 200, 0 = off)
  VAULT_MAX_CONTEXT_BYTES total bullet bytes (default 8192, 0 = off)

The default is set by the host, not by taste: Claude Code persists any hook
additionalContext over 10,000 CHARACTERS to a file and injects a 2 KB preview plus a
path instead — measured across 199 spilled hook-context files, the smallest is 10,435 B
and none is under 10,000. A block that spills delivers ~13 pointers inline; a block
budgeted to 8 KB delivers ~60 and never costs a Read. The byte budget is deliberately
conservative against a character threshold: bytes >= chars, so staying under in bytes
is always under in chars.

The budget is split PER SUBGRAPH, proportional to how many bullets each contributes.
A flat budget would spend itself on whichever subgraph is rendered first and leave a
second matched subgraph (a namespace-wide `shared/`, say) with nothing at all.
"""

import json
import os
import sys


def _limit(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, default))
    except ValueError:
        return default
    return value if value >= 0 else default


MAX_BULLET_CHARS = _limit("VAULT_MAX_BULLET_CHARS", 200)
# 7000, not 8192: the byte budget covers BULLETS only — headers, Entry paths, the
# retrieval trailer and the divergence/unswept-tail notices ride on top, and the
# worst measured block (multi-subgraph + notices) reached 9006 B against the host's
# 10,000-char spill ceiling. 7000 keeps ~1.2KB of unbudgeted overhead + real margin.
MAX_CONTEXT_BYTES = _limit("VAULT_MAX_CONTEXT_BYTES", 7000)
MIN_SECTION_BULLETS = 3  # every matched subgraph gets a voice, however small its share


def clamp(line: str) -> str:
    if not MAX_BULLET_CHARS or len(line) <= MAX_BULLET_CHARS:
        return line
    return line[:MAX_BULLET_CHARS].rstrip() + " …"


def guard(block: str) -> str:
    """Clamp each bullet, then keep as many as the per-section budget affords."""
    lines = block.split("\n")
    # Section = one subgraph, opened by its `### <id>` header. Everything before the first
    # header is the preamble and is never budgeted.
    sections, current = [[]], 0
    for line in lines:
        if line.startswith("### "):
            sections.append([])
            current += 1
        sections[current].append(line)

    counts = [sum(1 for l in sec if l.startswith("- ")) for sec in sections]
    total = sum(counts)
    if not total or not MAX_CONTEXT_BYTES:
        return "\n".join(clamp(l) if l.startswith("- ") else l for l in lines)

    out = []
    for sec, count in zip(sections, counts):
        share = int(MAX_CONTEXT_BYTES * count / total) if count else 0
        # Selection is NEWEST-FIRST, presentation stays in curated order. Capture
        # appends new bullets at the BOTTOM of an Entry list, and the old top-down
        # cut delivered the oldest pointers while omitting exactly the newest
        # captures (audit 2026-08-30: 4/5 of one subgraph's August bullets sat
        # past the cut). Walking the budget from the bottom keeps the freshest
        # pointers; the curated reading order of the survivors is preserved.
        bullet_idx = [i for i, l in enumerate(sec) if l.startswith("- ")]
        clamped = {i: clamp(sec[i]) for i in bullet_idx}
        keep = set()
        spent = 0
        for i in reversed(bullet_idx):
            cost = len(clamped[i].encode("utf-8")) + 1
            if spent + cost > share and len(keep) >= MIN_SECTION_BULLETS:
                break
            keep.add(i)
            spent += cost
        dropped = len(bullet_idx) - len(keep)
        notice_done = False
        for i, line in enumerate(sec):
            if not line.startswith("- "):
                out.append(line)
                continue
            if i in keep:
                out.append(clamped[i])
            elif not notice_done:
                # One notice, at the FIRST omitted slot — appended to the end it
                # would land after the retrieval trailer, describing a list the
                # reader has long since scrolled past.
                out.append(
                    f"({dropped} older entry node(s) omitted — open the Entry file "
                    f"above for the full list, or use `vault_search`.)"
                )
                notice_done = True
    return "\n".join(out)


def main() -> int:
    block = sys.stdin.read()
    if not block.strip():
        return 1
    json.dump(
        {
            "suppressOutput": True,
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": guard(block),
            },
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
