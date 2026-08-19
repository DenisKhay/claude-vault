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
MAX_CONTEXT_BYTES = _limit("VAULT_MAX_CONTEXT_BYTES", 8192)
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
        spent, kept, dropped, cut_at = 0, 0, 0, None
        for line in sec:
            if not line.startswith("- "):
                out.append(line)
                continue
            if dropped:
                dropped += 1
                continue
            line = clamp(line)
            spent += len(line.encode("utf-8")) + 1
            if spent > share and kept >= MIN_SECTION_BULLETS:
                dropped, cut_at = 1, len(out)  # note WHERE the list was cut, not just that it was
                continue
            out.append(line)
            kept += 1
        if dropped:
            # Insert at the cut, not at the section end — appended to the end it would land after
            # the retrieval trailer, describing a list the reader has long since scrolled past.
            out.insert(
                cut_at,
                f"({dropped} more entry node(s) omitted — open the Entry file above for the "
                f"full list, or use `vault_search`.)",
            )
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
