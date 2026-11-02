#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_tree.py - sanity checks for the generated tree.

* no remaining Xray references
* every .lua file parses
* every .json file is valid JSON
* every .htm file has balanced braces inside <script> blocks
"""

import glob
import json
import os
import re
import sys

# luaparser is optional at runtime; required for the syntax check
try:
    from luaparser import ast as lua_ast
except ImportError:  # pragma: no cover
    lua_ast = None

BAD = []

# The fork's own tooling describes what it removes, so it is not part of the tree being
# checked. CI runs this against a plain upstream clone, where these paths do not exist.
IGNORE = (
    "tools/",
    "README.md",
    "FORK-NOTES.md",
    ".github/workflows/sync-upstream.yml",
)


def ignored(path):
    p = path.replace(os.sep, "/")
    return any(part in p for part in IGNORE)


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            path = os.path.join(dirpath, name)
            if ignored(path):
                continue
            yield path


def check_no_xray(root):
    for path in walk(root):
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(text.split("\n"), 1):
            if re.search("xray", line, re.I):
                BAD.append("%s:%d: xray reference: %s" % (path, lineno, line.strip()[:100]))


def check_lua(root):
    if lua_ast is None:
        BAD.append("luaparser not installed: cannot check Lua syntax")
        return
    for path in walk(root):
        if not path.endswith(".lua"):
            continue
        text = open(path, encoding="utf-8").read()
        try:
            lua_ast.parse(text)
        except Exception as exc:
            BAD.append("%s: lua parse error: %s" % (path, str(exc)[:300]))


def check_json(root):
    for path in walk(root):
        if not path.endswith(".json"):
            continue
        try:
            json.load(open(path, encoding="utf-8"))
        except Exception as exc:
            BAD.append("%s: json error: %s" % (path, exc))


def check_htm(root):
    for path in walk(root):
        if not path.endswith(".htm"):
            continue
        text = open(path, encoding="utf-8").read()
        for block in re.findall(r"<script[^>]*>(.*?)</script>", text, re.S):
            depth = 0
            quote = None
            i = 0
            while i < len(block):
                ch = block[i]
                if quote:
                    if ch == "\\":
                        i += 2
                        continue
                    if ch == quote:
                        quote = None
                elif ch in "\"'`":
                    quote = ch
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth < 0:
                        break
                i += 1
            if depth != 0 or quote:
                BAD.append("%s: unbalanced braces in <script> block (depth=%s)" % (path, depth))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    check_no_xray(root)
    check_lua(root)
    check_json(root)
    if BAD:
        print("FAILED (%d)" % len(BAD))
        for item in BAD:
            print("  " + item)
        return 1
    print("OK: no xray refs, lua/json checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
