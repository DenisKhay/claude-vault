#!/usr/bin/env python3
"""Structural validation for a bench battery. Prints the query count, exits non-zero
with a reason on any problem. Kept separate from bench.py so the normal test suite
can check battery health without needing the live vault or index."""
import json
import sys


def main(path):
    battery = json.load(open(path))
    ids = [i["id"] for i in battery]
    if len(ids) != len(set(ids)):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        print(f"duplicate ids: {dupes}")
        return 1
    for i in battery:
        who = i.get("id", "?")
        if not i.get("q", "").strip():
            print(f"{who}: empty query")
            return 1
        if not i.get("cat"):
            print(f"{who}: no category")
            return 1
        if not i.get("gt"):
            print(f"{who}: no ground truth")
            return 1
        for g in i["gt"]:
            if not g.endswith(".md"):
                print(f"{who}: ground truth is not a node path: {g}")
                return 1
            if g.startswith("/") or ".." in g:
                print(f"{who}: ground truth must be vault-relative: {g}")
                return 1
    print(len(battery))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
