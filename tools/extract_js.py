#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""extract_js.py - pull the JS out of a LuCI .htm template for `node --check`.

LuCI templates mix Lua (<% ... %>) into the JS.  Those spans are replaced with a
neutral literal so the rest can be parsed by a real JavaScript parser.
"""

import re
import sys


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8").read()
    # Neutralise LuCI's Lua spans first: they may contain '>' and would otherwise
    # terminate the <script ...> tag early.
    text = re.sub(r"<%.*?%>", "0", text, flags=re.S)
    blocks = re.findall(r"<script[^>]*>(.*?)</script>", text, re.S)
    out = []
    for block in blocks:
        block = re.sub(r"^\s*//<!\[CDATA\[\s*$", "", block, flags=re.M)
        block = re.sub(r"^\s*//\]\]>\s*$", "", block, flags=re.M)
        out.append(block)
    open(dst, "w", encoding="utf-8").write("\n;\n".join(out))
    print("wrote %s (%d blocks)" % (dst, len(blocks)))


if __name__ == "__main__":
    main()
