#!/usr/bin/env python3
"""transcript-digest.py <transcript.jsonl> <out.md>

Render a Claude Code session transcript into a readable digest and mark every Stop-hook
capture sweep as a boundary line, so a reader (a spool worker, or a person) can see which
part of the session was already swept and which tail never was.

Prints one line to stdout:  boundaries=<n> tail_bytes=<n> total_bytes=<n>
tail_bytes counts user + assistant TEXT after the last boundary (tool calls and their
results are rendered but not counted — a tail of nothing but tool traffic has no knowledge
in it). The transcript format is undocumented and unstable; unknown entries are skipped,
never fatal.
"""
import json
import re
import sys

# The Stop hook's message is "Stop hook feedback:\n[bash …/prompt-actualize.sh]: …" — the
# newline after the colon is why a single-line regex missed every marker on first try.
MARK = re.compile(r"\Astop hook feedback:[\s\S]*prompt-actualize", re.IGNORECASE)
SKIP = re.compile(r"\A<(local-command-caveat|command-name|local-command-stdout)")


def clip(s, n):
    return s if len(s) <= n else s[:n] + " …[+%d chars]" % (len(s) - n)


def squash(s):
    return re.sub(r"\s+", " ", s).strip()


def main(src, out):
    lines = []
    sweeps = 0
    tail_bytes = 0
    total_bytes = 0

    def emit(s, counted=True):
        nonlocal tail_bytes, total_bytes
        lines.append(s)
        if counted:
            n = len(s.encode("utf-8"))
            tail_bytes += n
            total_bytes += n

    def boundary(ts):
        nonlocal sweeps, tail_bytes
        sweeps += 1
        lines.append(
            "\n#### ===== VAULT SWEEP BOUNDARY #%d (%s) — everything ABOVE was already swept by that session =====\n"
            % (sweeps, ts)
        )
        tail_bytes = 0

    with open(src, encoding="utf-8", errors="replace") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                e = json.loads(raw)
            except Exception:
                continue
            kind = e.get("type")
            if kind not in ("user", "assistant"):
                continue
            msg = e.get("message") or {}
            content = msg.get("content")
            ts = (e.get("timestamp") or "")[:16]
            if kind == "user":
                if isinstance(content, str):
                    blocks = [{"type": "text", "text": content}]
                elif isinstance(content, list):
                    blocks = content
                else:
                    blocks = []
                for b in blocks:
                    if not isinstance(b, dict):
                        continue
                    bt = b.get("type")
                    if bt == "text":
                        txt = (b.get("text") or "").strip()
                        if not txt or SKIP.match(txt):
                            continue
                        if MARK.match(txt):
                            boundary(ts)
                            continue
                        if txt.startswith("Base directory for this skill:"):
                            emit("\n[USER %s] (skill loaded: %s)" % (ts, squash(txt[:120])))
                            continue
                        if txt.startswith("<task-notification>"):
                            emit("\n[TASK-NOTIFICATION %s] %s" % (ts, clip(squash(txt), 600)))
                            continue
                        emit("\n[USER %s] %s" % (ts, clip(txt, 4000)))
                    elif bt == "tool_result":
                        cc = b.get("content")
                        if isinstance(cc, str):
                            txt = cc
                        elif isinstance(cc, list):
                            txt = "\n".join(
                                x.get("text", "") for x in cc if isinstance(x, dict) and x.get("type") == "text"
                            )
                        else:
                            txt = ""
                        txt = squash(txt)
                        if txt:
                            emit("  [TOOL-RESULT] %s" % clip(txt, 350), counted=False)
            else:
                if not isinstance(content, list):
                    continue
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    bt = b.get("type")
                    if bt == "text":
                        txt = (b.get("text") or "").strip()
                        if txt:
                            emit("\n[ASSISTANT %s] %s" % (ts, clip(txt, 6000)))
                    elif bt == "tool_use":
                        i = b.get("input") or {}
                        d = ""
                        if isinstance(i, dict):
                            for k in ("command", "file_path", "path", "pattern", "description", "prompt", "query", "url"):
                                if i.get(k):
                                    d = i[k]
                                    break
                        if not isinstance(d, str):
                            d = json.dumps(d)
                        emit("  [TOOL %s] %s" % (b.get("name"), clip(squash(d), 240)), counted=False)

    lines.append(
        "\n#### END OF TRANSCRIPT — %d sweep boundaries; the part after the LAST boundary is unswept." % sweeps
    )
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("boundaries=%d tail_bytes=%d total_bytes=%d" % (sweeps, tail_bytes, total_bytes))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: transcript-digest.py <transcript.jsonl> <out.md>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
