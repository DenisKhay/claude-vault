#!/usr/bin/env python3
"""Render a SessionStart context block as hook JSON on stdout, size-guarded.

Reads the assembled block on STDIN (never argv — a single argv string is capped at
MAX_ARG_STRLEN, 128 KiB, and passing the block to `jq --arg` blew that ceiling on a
real vault: one subgraph's Entry-nodes list had grown to 110 KiB, the hook died with
"Argument list too long" and every session started with NO vault context at all).

Two guards, both on the bullet lines only — headers, entry paths and the retrieval
trailer always survive, so a truncated block still tells the model how to search:
  VAULT_MAX_BULLET_CHARS  per-bullet clamp   (default 200, 0 = off)
  VAULT_MAX_CONTEXT_BYTES total bullet bytes (default 32768, 0 = off)
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
MAX_CONTEXT_BYTES = _limit("VAULT_MAX_CONTEXT_BYTES", 32768)


def clamp(line: str) -> str:
    if not MAX_BULLET_CHARS or len(line) <= MAX_BULLET_CHARS:
        return line
    return line[:MAX_BULLET_CHARS].rstrip() + " …"


def guard(block: str) -> str:
    kept, spent, dropped = [], 0, 0
    for line in block.split("\n"):
        if not line.startswith("- "):
            kept.append(line)
            continue
        if dropped:
            dropped += 1
            continue
        line = clamp(line)
        spent += len(line.encode("utf-8")) + 1
        if MAX_CONTEXT_BYTES and spent > MAX_CONTEXT_BYTES:
            dropped = 1
            continue
        kept.append(line)
    if dropped:
        kept.append(
            f"\n({dropped} more entry-node line(s) omitted — the list outgrew the "
            f"{MAX_CONTEXT_BYTES}-byte budget. Read the _index.md above, or use `vault_search`.)"
        )
    return "\n".join(kept)


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
