#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
strip_xray.py - rewrite an upstream openwrt-passwall2 tree into the sing-box-only fork.

Why a script instead of a merge
-------------------------------
The fork must track upstream. Instead of resolving merge conflicts by hand every time
upstream touches a file we edited, we re-derive the fork deterministically:

    upstream tree  --(this script)-->  fork tree

Every rule asserts on an anchor. When upstream moves code, the script fails loudly and
names the broken rule instead of silently producing a broken package.

Usage:
    python3 tools/strip_xray.py <repo-root>
"""

import os
import re
import sys


class RuleError(Exception):
    pass


def read(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


class Tree:
    def __init__(self, root):
        self.root = root
        self.applied = []

    def path(self, rel):
        return os.path.join(self.root, rel)

    def exists(self, rel):
        return os.path.exists(self.path(rel))

    def remove_file(self, rel):
        p = self.path(rel)
        if not os.path.exists(p):
            raise RuleError("remove_file: missing %s" % rel)
        os.remove(p)
        self.applied.append("remove_file %s" % rel)

    def text(self, rel):
        if not self.exists(rel):
            raise RuleError("missing file: %s" % rel)
        return read(self.path(rel))

    def save(self, rel, text):
        write(self.path(rel), text)

    def sub(self, rel, old, new, count=1):
        """Exact substring replacement; must hit `count` times."""
        text = self.text(rel)
        n = text.count(old)
        if n != count:
            raise RuleError(
                "%s: expected %d hit(s), got %d\n  anchor: %r" % (rel, count, n, old)
            )
        self.save(rel, text.replace(old, new))
        self.applied.append("sub %s" % rel)

    def resub(self, rel, pattern, new, expect=1, flags=0):
        text = self.text(rel)
        rx = re.compile(pattern, flags)
        n = len(rx.findall(text))
        if n != expect:
            raise RuleError(
                "%s: regex hit %d time(s), expected %d\n  pattern: %s"
                % (rel, n, expect, pattern)
            )
        self.save(rel, rx.sub(new, text))
        self.applied.append("resub %s" % rel)

    def drop_lines(self, rel, pattern, expect, flags=0):
        """Delete whole lines matching `pattern`."""
        text = self.text(rel)
        rx = re.compile(pattern, flags)
        kept = []
        dropped = 0
        for line in text.split("\n"):
            if rx.search(line):
                dropped += 1
                continue
            kept.append(line)
        if dropped != expect:
            raise RuleError(
                "%s: drop_lines hit %d line(s), expected %d\n  pattern: %s"
                % (rel, dropped, expect, pattern)
            )
        self.save(rel, "\n".join(kept))
        self.applied.append("drop_lines %s" % rel)


    def drop_block(self, rel, start_pat, end_pat, flags=0):
        """Delete lines from the first match of start_pat through the next end_pat."""
        text = self.text(rel)
        lines = text.split("\n")
        srx, erx = re.compile(start_pat, flags), re.compile(end_pat, flags)
        start = None
        for idx, line in enumerate(lines):
            if srx.search(line):
                start = idx
                break
        if start is None:
            raise RuleError("%s: drop_block start not found: %s" % (rel, start_pat))
        end = None
        for idx in range(start + 1, len(lines)):
            if erx.search(lines[idx]):
                end = idx
                break
        if end is None:
            raise RuleError("%s: drop_block end not found: %s" % (rel, end_pat))
        del lines[start:end + 1]
        self.save(rel, "\n".join(lines))
        self.applied.append("drop_block %s" % rel)

    def drop_po_blocks(self, rel, expect):
        """Drop .po entries (blank-line separated) whose text mentions Xray."""
        text = self.text(rel)
        blocks = re.split(r"\n\s*\n", text)
        kept, dropped = [], 0
        for block in blocks:
            if "Xray" in block:
                dropped += 1
                continue
            kept.append(block)
        if dropped != expect:
            raise RuleError("%s: dropped %d po block(s), expected %d" % (rel, dropped, expect))
        self.save(rel, "\n\n".join(kept))
        self.applied.append("drop_po_blocks %s (%d)" % (rel, dropped))


# ---------------------------------------------------------------------------
# Lua: prune if / elseif arms whose condition mentions Xray
# ---------------------------------------------------------------------------

XRAY_MARKERS = [
    r"\bhas_xray\b",
    r"[\"'][^\"']*[Xx]ray[^\"']*[\"']",
]


def has_xray_marker(text):
    return any(re.search(p, text) for p in XRAY_MARKERS)


def _split_top(expr, keywords):
    """Split an expression on top-level (outside parens / strings) connectors."""
    parts = []
    depth = 0
    i = 0
    start = 0
    n = len(expr)

    def boundary_before(idx):
        return idx == 0 or expr[idx - 1] in " \t()"

    def boundary_after(idx):
        return idx >= n or expr[idx] in " \t()"

    while i < n:
        ch = expr[i]
        if ch in "\"'":
            quote = ch
            i += 1
            while i < n:
                if expr[i] == "\\":
                    i += 2
                    continue
                if expr[i] == quote:
                    break
                i += 1
            i += 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif depth == 0:
            for kw in keywords:
                if expr.startswith(kw, i):
                    if boundary_before(i) and boundary_after(i + len(kw)):
                        parts.append(expr[start:i])
                        i += len(kw)
                        start = i
                        break
            else:
                i += 1
                continue
            continue
        i += 1
    parts.append(expr[start:])
    return parts


def _strip_parens(expr):
    e = expr.strip()
    if not e.startswith("("):
        return None
    depth = 0
    for idx, ch in enumerate(e):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return e[1:-1] if idx == len(e) - 1 else None
    return None


def simplify_cond(cond):
    """Drop Xray disjuncts from a condition; return None when it is always false."""
    cond = cond.strip()
    js_style = "&&" in cond or "||" in cond
    and_op = " && " if js_style else " and "
    or_op = " || " if js_style else " or "
    simplified = []
    for term in _split_top(cond, ["and", "&&"]):
        kept = []
        for piece in _split_top(term, ["or", "||"]):
            piece = piece.strip()
            inner = _strip_parens(piece)
            if inner is not None:
                sub = simplify_cond(inner)
                if sub is None:
                    continue
                if len(_split_top(sub, ["or", "||"])) > 1:
                    kept.append("(" + sub + ")")
                else:
                    kept.append(sub)
                continue
            if has_xray_marker(piece):
                continue
            kept.append(piece)
        if not kept:
            return None
        simplified.append(or_op.join(kept) if len(kept) > 1 else kept[0])
    return and_op.join(simplified)


_ARM_START = re.compile(r"^(\t*)(if|elseif)\s+(.*?)\s+then\s*$")
_ELSE = re.compile(r"^(\t*)else\s*$")
_END = re.compile(r"^(\t*)end\s*$")


def prune_lua_arms(tree, rel):
    """Delete Xray-only if/elseif arms while keeping the else-chain semantics."""
    lines = tree.text(rel).split("\n")
    removed = 0
    i = 0
    guard = 0
    while i < len(lines):
        guard += 1
        if guard > 200000:
            raise RuleError("%s: pruning loop runaway" % rel)
        m = _ARM_START.match(lines[i])
        if not m or not has_xray_marker(m.group(3)):
            i += 1
            continue
        indent, kind, cond = m.group(1), m.group(2), m.group(3)
        new_cond = simplify_cond(cond)
        if new_cond is not None:
            word = "if" if kind == "if" else "elseif"
            lines[i] = "%s%s %s then" % (indent, word, new_cond)
            removed += 1
            i += 1
            continue
        # always-false arm: find where it ends
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if line.startswith(indent) and not line.startswith(indent + "\t"):
                if line.startswith(indent + "elseif ") or _ELSE.match(line) or _END.match(line):
                    break
            j += 1
        if j >= len(lines):
            raise RuleError("%s:%d unclosed branch" % (rel, i + 1))
        nxt = lines[j]
        if kind == "elseif":
            del lines[i:j]
            removed += 1
            continue
        if nxt.startswith(indent + "elseif "):
            del lines[i:j]
            lines[i] = re.sub(r"^(\t*)elseif\b", r"\1if", lines[i], count=1)
            removed += 1
            continue
        if _ELSE.match(nxt):
            k = j + 1
            while k < len(lines):
                if _END.match(lines[k]) and len(_END.match(lines[k]).group(1)) == len(indent):
                    break
                k += 1
            if k >= len(lines):
                raise RuleError("%s:%d unclosed else" % (rel, j + 1))
            body = [ln[1:] if ln.startswith("\t") else ln for ln in lines[j + 1:k]]
            lines[i:k + 1] = body
            removed += 1
            continue
        if _END.match(nxt):
            del lines[i:j + 1]
            removed += 1
            continue
        raise RuleError("%s:%d unexpected branch end: %r" % (rel, i + 1, nxt))
    tree.save(rel, "\n".join(lines))
    tree.applied.append("prune_lua_arms %s (%d)" % (rel, removed))
    return removed


_JS_IF = re.compile(r"^(\t*)if \((.*)\) \{\s*$")
_JS_ELSEIF = re.compile(r"^(\t*)\} else if \((.*)\) \{\s*$")
_JS_ELSE = re.compile(r"^(\t*)\} else \{\s*$")
_JS_CLOSE = re.compile(r"^(\t*)\}\s*$")


def prune_js_arms(tree, rel):
    """Delete Xray-only if / else-if arms from the LuCI JS templates."""
    lines = tree.text(rel).split("\n")
    removed = 0
    i = 0
    guard = 0
    while i < len(lines):
        guard += 1
        if guard > 200000:
            raise RuleError("%s: js pruning loop runaway" % rel)
        m = _JS_IF.match(lines[i]) or _JS_ELSEIF.match(lines[i])
        if not m:
            i += 1
            continue
        is_elseif = lines[i].lstrip().startswith("}")
        indent, cond = m.group(1), m.group(2)
        if not has_xray_marker(cond):
            i += 1
            continue
        new_cond = simplify_cond(cond)
        if new_cond is not None:
            head = "} else if " if is_elseif else "if "
            lines[i] = "%s%s(%s) {" % (indent, head, new_cond)
            removed += 1
            i += 1
            continue
        # always-false arm
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if len(indent_of(line)) == len(indent) and (
                _JS_ELSEIF.match(line) or _JS_ELSE.match(line) or _JS_CLOSE.match(line)
            ):
                break
            j += 1
        if j >= len(lines):
            raise RuleError("%s:%d unclosed js branch" % (rel, i + 1))
        if is_elseif:
            del lines[i:j]
            removed += 1
            continue
        if _JS_ELSEIF.match(lines[j]):
            del lines[i:j]
            lines[i] = re.sub(r"^\t*\} else if ", indent + "if ", lines[i], count=1)
            removed += 1
            continue
        if _JS_ELSE.match(lines[j]):
            k = j + 1
            while k < len(lines):
                if _JS_CLOSE.match(lines[k]) and len(indent_of(lines[k])) == len(indent):
                    break
                k += 1
            if k >= len(lines):
                raise RuleError("%s:%d unclosed js else" % (rel, j + 1))
            body = [ln[1:] if ln.startswith("\t") else ln for ln in lines[j + 1:k]]
            lines[i:k + 1] = body
            removed += 1
            continue
        if _JS_CLOSE.match(lines[j]):
            del lines[i:j + 1]
            removed += 1
            continue
        raise RuleError("%s:%d unexpected js branch end: %r" % (rel, i + 1, lines[j]))
    tree.save(rel, "\n".join(lines))
    tree.applied.append("prune_js_arms %s (%d)" % (rel, removed))
    return removed


def indent_of(line):
    return line[: len(line) - len(line.lstrip("\t"))]


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

APP = "luci-app-passwall2"

DELETE_FILES = [
    APP + "/luasrc/model/cbi/passwall2/client/type/2_xray.lua",
    APP + "/luasrc/model/cbi/passwall2/server/type/2_xray.lua",
    APP + "/luasrc/passwall2/util_xray.lua",
]

LUA_FILES = [
    APP + "/luasrc/controller/passwall2.lua",
    APP + "/luasrc/model/cbi/passwall2/client/acl_config.lua",
    APP + "/luasrc/model/cbi/passwall2/client/global.lua",
    APP + "/luasrc/model/cbi/passwall2/client/node_config.lua",
    APP + "/luasrc/model/cbi/passwall2/client/node_list.lua",
    APP + "/luasrc/model/cbi/passwall2/client/node_subscribe.lua",
    APP + "/luasrc/model/cbi/passwall2/client/node_subscribe_config.lua",
    APP + "/luasrc/model/cbi/passwall2/client/other.lua",
    APP + "/luasrc/model/cbi/passwall2/client/socks_config.lua",
    APP + "/luasrc/model/cbi/passwall2/client/include/shunt_options.lua",
    APP + "/luasrc/model/cbi/passwall2/server/index.lua",
    APP + "/luasrc/passwall2/api.lua",
    APP + "/luasrc/passwall2/com.lua",
    APP + "/luasrc/passwall2/server_app.lua",
    APP + "/luasrc/passwall2/util_sing-box.lua",
    APP + "/root/usr/share/passwall2/subscribe.lua",
    APP + "/root/usr/share/passwall2/app_acl.lua",
]

SUB = APP + "/root/usr/share/passwall2/subscribe.lua"
GLOBAL = APP + "/luasrc/model/cbi/passwall2/client/global.lua"
NODE_SUB = APP + "/luasrc/model/cbi/passwall2/client/node_subscribe.lua"
NODE_SUB_CFG = APP + "/luasrc/model/cbi/passwall2/client/node_subscribe_config.lua"
SOCKS = APP + "/luasrc/model/cbi/passwall2/client/socks_config.lua"
OTHER = APP + "/luasrc/model/cbi/passwall2/client/other.lua"
COM = APP + "/luasrc/passwall2/com.lua"


def rules_lua(tree):
    # 1. drop has_xray / xray_version locals that no longer have users
    tree.drop_lines(GLOBAL, r"^has_xray = api\.finded_com\(\"xray\"\)$", 1)
    tree.drop_lines(NODE_SUB, r"^(local has_xray|local xray_version)", 2)
    tree.drop_lines(NODE_SUB_CFG, r"^(local has_xray|local xray_version)", 2)
    tree.drop_lines(SOCKS, r"^local has_xray = api\.finded_com\(\"xray\"\)$", 1)
    tree.drop_lines(OTHER, r"^local has_xray = api\.finded_com\(\"xray\"\)$", 1)
    tree.drop_lines(SUB, r"^local has_xray = api\.finded_com\(\"xray\"\)$", 1)

    # 2. subscription: default core table loses its {has_xray,"xray"} entries
    tree.resub(SUB, r',\{has_xray,"xray"\}', "", expect=3)
    tree.resub(SUB, r'\{has_xray,"xray"\},', "", expect=2)
    tree.resub(SUB, r'^\t\["xray"\] = has_xray,\n', "", expect=1, flags=re.M)

    # 3. com.lua: drop the Xray component registration
    tree.drop_lines(COM, r'^\t"xray",$', 1)
    tree.resub(COM, r"_M\.xray = \{.*?\n\}\n\n", "", expect=1, flags=re.S)

    # 4. transport helper expressions
    tree.resub(SUB, r'\(result\.type == "Xray"\) and "xhttp" or "http"', '"http"', expect=4)


HTML = APP + "/luasrc/view/passwall2/node_config/link_share_man.htm"
API = APP + "/luasrc/passwall2/api.lua"
SINGBOX_UTIL = APP + "/luasrc/passwall2/util_sing-box.lua"
APPL = APP + "/root/usr/share/passwall2/app.sh"
MAKEFILE = APP + "/Makefile"
DEFAULT_CFG = APP + "/root/usr/share/passwall2/0_default_config"
WORKFLOW = ".github/workflows/Auto compile with openwrt sdk.yml"
NODE_LIST_HTM = APP + "/luasrc/view/passwall2/node_list/node_list.htm"
SHUNT_HTM = APP + "/luasrc/view/passwall2/rule/shunt_rule_list.htm"


def rules_html(tree):
    """LuCI template: Lua header + embedded JS."""
    tree.drop_lines(HTML, r'^local has_xray = api\.finded_com\("xray"\)$', 1)
    tree.resub(HTML, r',\{has_xray,"xray"\}', "", expect=2)
    tree.resub(HTML, r'\{has_xray,"xray"\},', "", expect=2)
    tree.resub(HTML, r', \{has_xray,"xray"\}', "", expect=1)
    tree.drop_lines(HTML, r'^\tlet has_xray = "<%=has_xray%>"$', 1)

    prune_js_arms(tree, HTML)

    # import helper: xray is no longer a fallback for SS plugins
    tree.sub(
        HTML,
        'const needUpgrade = ss_type !== "Xray" && ss_type !== "sing-box" &&',
        'const needUpgrade = ss_type !== "sing-box" &&',
    )
    # trojan has no xray fallback any more
    tree.resub(
        HTML,
        r'\n\t*\} else \{\n\t*dom_prefix = "xray_";\n'
        r"\t*opt\.set\('type', \"Xray\"\);\n\t*opt\.set\(dom_prefix \+ 'protocol', \"trojan\"\);\n(\t*)\}",
        r"\n\1}",
    )
    # hysteria2: only sing-box
    tree.resub(
        HTML,
        r'\n(\t*)var is_singbox = hysteria2_type == "sing-box" && has_singbox;\n'
        r"\t*opt\.set\('type', is_singbox \? \"sing-box\" : \"Xray\"\);\n"
        r'\t*dom_prefix = is_singbox \? "singbox_" : "xray_";',
        "\n\\1opt.set('type', \"sing-box\");\n\\1dom_prefix = \"singbox_\";",
    )
    tree.sub(
        HTML,
        """opt.set('type', dom_prefix == "singbox_" ? "sing-box" : "Xray")""",
        """opt.set('type', "sing-box")""",
    )
    # vless import: sing-box is the only target
    tree.resub(
        HTML,
        r'\n(\t*)if \(vless_type == "sing-box" && has_singbox\) \{\n'
        r'\t*dom_prefix = "singbox_";\n'
        r"\t*\} else \{\n"
        r'\t*dom_prefix = "xray_";\n'
        r"\t*\}",
        r'\n\1dom_prefix = "singbox_";',
    )
    tree.drop_lines(
        HTML,
        r"^\t*// The obfs-local plugin converts data to a format supported by xray\.$",
        1,
    )


def rules_api(tree):
    tree.drop_block(API, r"^function sha256_sb_xray\(str\)$", r"^end$")
    tree.sub(API, "function sha256_xray_sb(str)", "function sha256_hex2b64(str)")
    tree.sub(SINGBOX_UTIL, "api.sha256_xray_sb(", "api.sha256_hex2b64(")
    tree.drop_block(API, r'^\tlocal xray = finded_com\("xray"\)$', r"^\tend$")

    # comments that describe the removed core
    tree.sub(
        SINGBOX_UTIL,
        '--api.log(0, "V2ray/Xray Geo convert to Sing-Box rule-set:")',
        '--api.log(0, "V2ray Geo convert to Sing-Box rule-set:")',
    )
    tree.resub(SINGBOX_UTIL, r'--兼容xray "域名\+DNS" 格式ech', "--兼容 \"域名+DNS\" 格式ech", expect=1)
    tree.sub(
        SINGBOX_UTIL,
        "-- For compatibility with Xray-core, set it to Sec-WebSocket-Protocol. It needs to be consistent with the server.",
        "-- Sec-WebSocket-Protocol header, it needs to be consistent with the server.",
        count=2,
    )
    tree.sub(
        SINGBOX_UTIL,
        "-- There is no additional encryption support: it's essentially re-encryption. And Xray-core is incompatible with v2ray-core here.",
        "-- There is no additional encryption support: it's essentially re-encryption.",
        count=2,
    )
    tree.sub(
        SINGBOX_UTIL,
        ", -- UDP packet encoding. (Empty): Disabled. packetaddr: Supported by v2ray 5+. xudp: Supported by xray.",
        ", -- UDP packet encoding. (Empty): Disabled. packetaddr: Supported by v2ray 5+.",
        count=2,
    )


def rules_strings(tree):
    tree.sub(
        APP + "/luasrc/model/cbi/passwall2/client/node_subscribe_config.lua",
        'translate("Supports only Xray or Sing-box node types.")',
        'translate("Supports only Sing-box node types.")',
    )
    tree.sub(
        APP + "/luasrc/model/cbi/passwall2/client/node_subscribe_config.lua",
        'local descrStr = "Chained proxy works only with Xray or Sing-box nodes.<br>"',
        'local descrStr = "Chained proxy works only with Sing-box nodes.<br>"',
    )
    tree.sub(
        APP + "/luasrc/model/cbi/passwall2/client/shunt_rules.lua",
        '"Sing-Box/Xray " .. translate("Shunt Rule")',
        '"Sing-Box " .. translate("Shunt Rule")',
    )
    tree.sub(
        SHUNT_HTM,
        "<h3>Sing-Box/Xray <%:Shunt Rule%></h3>",
        "<h3>Sing-Box <%:Shunt Rule%></h3>",
    )
    tree.drop_lines(
        APP + "/luasrc/model/cbi/passwall2/client/type/3_ss-rust.lua",
        r'^if api\.is_finded\("xray-plugin"\) then o:value\("xray-plugin"\) end$',
        1,
    )
    tree.sub(
        APP + "/luasrc/model/cbi/passwall2/client/acl_config.lua",
        'o = s:taboption("Main", HideValue, "_is_xray")\no:depends("_hide", "1")\n\n',
        "",
    )
    tree.sub(
        NODE_LIST_HTM,
        'if (type == "sing-box" || type == "Xray") {',
        'if (type == "sing-box") {',
    )

    # subscription generator strings
    tree.resub(
        SUB,
        r'\n(\t*)local is_singbox = sub_hysteria2_type == "sing-box" and has_singbox\n'
        r"\t*result\.type = is_singbox and 'sing-box' or 'Xray'",
        r"\n\1result.type = 'sing-box'",
    )
    tree.sub(
        SUB,
        'i18n.translatef("Xray Load Balancing node [%s] list", node_id)',
        'i18n.translatef("Sing-Box Load Balancing node [%s] list", node_id)',
    )
    tree.sub(
        SUB,
        'i18n.translatef("Xray Load Balancing node [%s] backup node", node_id)',
        'i18n.translatef("Sing-Box Load Balancing node [%s] backup node", node_id)',
    )
    tree.sub(
        SUB,
        "\"Skip node: %s. Because Sing-Box does not support the %s protocol's %s transmission method, Xray needs to be used instead.\"",
        "\"Skip node: %s. Because Sing-Box does not support the %s protocol's %s transmission method.\"",
        count=3,
    )
    tree.sub(
        SUB,
        'local need_upgrade = (result.type ~= "Xray" and result.type ~= "sing-box")',
        'local need_upgrade = (result.type ~= "sing-box")',
    )
    tree.sub(
        SUB,
        '"Please replace Xray or Sing-Box to support more transmission methods in Shadowsocks."',
        '"Please replace Sing-Box to support more transmission methods in Shadowsocks."',
    )


def rules_app_sh(tree):
    tree.drop_lines(APPL, r"^UTIL_XRAY=", 1)
    tree.drop_lines(APPL, r"^XRAY_BIN=", 1)
    tree.drop_block(APPL, r"^run_xray\(\) \{$", r"^\}$")

    tree.sub(
        APPL,
        'if [ "$type" == "sing-box" ] || [ "$type" == "xray" ]; then',
        'if [ "$type" == "sing-box" ]; then',
    )
    tree.drop_block(APPL, r"^\txray\)$", r"^\t;;$")
    tree.sub(APPL, ' && [ "$type" != "xray" ]', "", count=2)
    tree.drop_block(APPL, r'^\t\telif \[ -n "\$\{XRAY_BIN\}" \]; then$', r'^\t\t\tlocal util="\$\{UTIL_XRAY\}"$')
    tree.drop_lines(APPL, r'^\t\[ -n "\$\{XRAY_BIN\}" \] && run_func="run_xray"$', 1)
    tree.resub(
        APPL,
        r'\t\tif \[ "\$\{type\}" = "xray" \] && \[ -n "\$\{XRAY_BIN\}" \]; then\n'
        r'\t\t\trun_func="run_xray"\n\t\telif ',
        '\t\tif ',
    )
    tree.drop_lines(APPL, r"^\texport XRAY_LOCATION_ASSET=", 1)
    tree.drop_lines(APPL, r"^\tunset XRAY_LOCATION_ASSET$", 1)
    tree.sub(
        APPL,
        "# kill_all xray-plugin v2ray-plugin obfs-local shadow-tls",
        "# kill_all v2ray-plugin obfs-local shadow-tls",
    )


def rules_meta(tree):
    # Makefile: sing-box is the only basic core
    tree.sub(
        MAKEFILE,
        "\tdefault PACKAGE_$(PKG_NAME)_Basic_Core_All if aarch64||arm||i386||x86_64\n"
        "\tdefault PACKAGE_$(PKG_NAME)_Basic_Core_Xray\n"
        "\n"
        "\tconfig PACKAGE_$(PKG_NAME)_Basic_Core_Xray\n"
        '\t\ttristate "Xray"\n'
        "\t\tselect PACKAGE_xray-core\n",
        "\tdefault PACKAGE_$(PKG_NAME)_Basic_Core_SingBox\n",
    )
    tree.sub(
        MAKEFILE,
        "\n\tconfig PACKAGE_$(PKG_NAME)_Basic_Core_All\n"
        '\t\tbool "All"\n'
        "\t\tselect PACKAGE_xray-core\n"
        "\t\tselect PACKAGE_sing-box",
        "",
    )

    # default uci config: the fork ships its own settings template (no nodes at all)
    tree.save(DEFAULT_CFG, fork_file("0_default_config"))
    tree.applied.append("default_config from tools/ui/0_default_config")

    # README
    tree.drop_lines(
        "README.md",
        r"^   > If installation fails due to missing dependencies \(e\.g\., `xray-core`\)",
        1,
    )
    tree.drop_lines("README.md", r"^- Xray$", 1)
    tree.drop_lines("README.md", r"^- \*\*Xray\*\* ", 1)

    # CI package list
    tree.sub(WORKFLOW, " v2ray-plugin xray-core", " v2ray-plugin", count=2)


def rules_po(tree):
    for lang in ("fa", "ru", "zh-cn", "zh-tw"):
        tree.drop_po_blocks(APP + "/po/%s/passwall2.po" % lang, 9)


# ---------------------------------------------------------------------------
# Fork UI: component-update page layout + log font.
#
# These are our own tweaks on top of upstream. They run after the Xray removal and
# must stay idempotent, because every sync re-applies them to a fresh upstream tree.
# ---------------------------------------------------------------------------

APP_UPDATE_LUA = APP + "/luasrc/model/cbi/passwall2/client/app_update.lua"
APP_VERSION_HTM = APP + "/luasrc/view/passwall2/app_update/app_version.htm"
LOG_HTM = APP + "/luasrc/view/passwall2/log/log.htm"
SERVER_LOG_HTM = APP + "/luasrc/view/passwall2/server/log.htm"

CSS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui", "app_version.css")

# upstream's three rules for the version rows; replaced wholesale by tools/ui/app_version.css
CSS_OLD = (
    "\t#app_version > .cbi-value {\n"
    "\t\tdisplay: flex;\n"
    "\t\tflex-wrap: wrap;\n"
    "\t\talign-items: center;\n"
    "\t\tmargin-top: 0;\n"
    "\t\tmargin-bottom: 0;\n"
    "\t\tpadding-top: .25rem;\n"
    "\t\tpadding-bottom: .25rem;\n"
    "\t}\n"
    "\t#app_version > .cbi-value > .cbi-value-title {\n"
    "\t\tpadding-top: 0;\n"
    "\t\tpadding-bottom: 0;\n"
    "\t\tline-height: 1.2;\n"
    "\t}\n"
    "\t#app_version .app-version-sub {\n"
    "\t\tdisplay: block;\n"
    "\t\tfont-size: .85em;\n"
    "\t\tfont-weight: normal;\n"
    "\t\topacity: .7;\n"
    "\t}"
)


def fork_style_block():
    """The fork's <style> content, kept in tools/ui/app_version.css."""
    with open(CSS_FILE, encoding="utf-8") as f:
        css = f.read()
    return css.strip("\n")


def fork_file(name):
    """A file the fork owns verbatim, kept in tools/ui/."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui", name)
    with open(path, encoding="utf-8") as f:
        return f.read()


PW_ROW_HEAD = '<div class="cbi-value">\n\t<label class="cbi-value-title">Passwall2 <%:Version%>'
LOOP_HEAD = "<%for _, k in ipairs(com.order) do"
LOOP_ROW_HEAD = '<div class="cbi-value">\n\t<label class="cbi-value-title"><%=v.name%>'

LOOP_LABEL_OLD = (
    '\t<label class="cbi-value-title"><%=v.name%>\n'
    "\t\t<%:Version%>\n"
    '\t\t<span class="app-version-sub"><span class="com_version" key="<%=k%>"><%=translate("Null")%></span></span>\n'
    "\t</label>\n"
    '\t<div class="cbi-value-field">\n'
    '\t\t<div class="cbi-value-description">\n'
)
LOOP_LABEL_NEW = (
    '\t<label class="cbi-value-title"><%=v.name%> <%:Version%></label>\n'
    '\t<div class="cbi-value-field">\n'
    '\t\t<div class="cbi-value-description">\n'
    '\t\t\t<span class="app-version-sub">【 <span class="com_version" key="<%=k%>"><%=translate("Null")%></span> 】</span>\n'
)
PW_LABEL_OLD = (
    '\t<label class="cbi-value-title">Passwall2 <%:Version%>\n'
    '\t\t<span class="app-version-sub"><%=api.get_version()%></span>\n'
    "\t</label>\n"
    '\t<div class="cbi-value-field">\n'
    '\t\t<div class="cbi-value-description">\n'
)
PW_LABEL_NEW = (
    '\t<label class="cbi-value-title">Passwall2 <%:Version%></label>\n'
    '\t<div class="cbi-value-field">\n'
    '\t\t<div class="cbi-value-description">\n'
    '\t\t\t<span class="app-version-sub">【 <%=api.get_version()%> 】</span>\n'
)

BOX_JS = (
    '<script type="text/javascript">\n'
    "\t//<![CDATA[\n"
    '\tdocument.addEventListener("DOMContentLoaded", function () {\n'
    '\t\tvar elm = document.getElementById("app_version");\n'
    "\t\tif (!elm || !elm.closest) return;\n"
    '\t\tvar box = elm.closest(".cbi-section-node");\n'
    '\t\tif (box) box.classList.add("passwall2-update-box");\n'
    "\t});\n"
    "\t//]]>\n"
    "</script>\n"
)

LOG_STYLE = """</script>
<style>
	/* Log output: pin font size/family so the page does not inherit an oversized
	   textarea font from the LuCI theme. */
	#log_textarea {
		font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
		font-size: 12px;
		line-height: 1.45;
	}
</style>
<fieldset class="cbi-section" id="_log_fieldset">"""


def rules_fork_ui(tree):
    # 1. the in-app updater must look at this repository, not the upstream API cache
    tree.sub(
        COM,
        "-- The LuCI package has its own update flow and is not a binary component.\n"
        "_M.passwall2 = {\n"
        '\tname = "PassWall2",\n'
        "\tget_url = gh_release_url\n"
        "}",
        "-- The LuCI package has its own update flow and is not a binary component.\n"
        "-- This fork publishes its own releases, so the in-app updater must look at this\n"
        "-- repository instead of the upstream API cache.\n"
        'local FORK_RELEASES = "https://api.github.com/repos/lima-droid/openwrt-passwall2/releases/latest"\n'
        "\n"
        "_M.passwall2 = {\n"
        '\tname = "PassWall2",\n'
        "\tget_url = function(self)\n"
        "\t\treturn FORK_RELEASES\n"
        "\tend\n"
        "}",
    )

    # 2. drop the "run from /tmp" hint and the GitHub-proxy description
    tree.sub(
        APP_UPDATE_LUA,
        'o = s:option(DummyValue, "tips", " ")\n'
        "o.rawhtml = true\n"
        "o.cfgvalue = function(t, n)\n"
        "\treturn string.format('<font color=\"red\">%s</font>', translate(\"if you want to run from memory, change the path, /tmp beginning then save the application and update it manually.\"))\n"
        "end\n"
        "\n",
        "",
    )
    tree.sub(
        APP_UPDATE_LUA,
        'o = s:option(ListValue, "gh_proxy_url", translate("GitHub Proxy"), translate("Use GitHub instead of proxy nodes for component updates."))',
        'o = s:option(ListValue, "gh_proxy_url", translate("GitHub Proxy"))',
    )

    # 3. component rows first (Geoview, Sing-Box), Passwall2 last, buttons aligned
    text = tree.text(APP_VERSION_HTM)
    if CSS_OLD not in text:
        raise RuleError("%s: app-version style anchor changed" % APP_VERSION_HTM)
    text = text.replace(CSS_OLD, fork_style_block(), 1)

    if PW_ROW_HEAD not in text:
        raise RuleError("%s: Passwall2 row anchor changed" % APP_VERSION_HTM)
    i = text.index(PW_ROW_HEAD)
    j = text.index(LOOP_HEAD, i)
    block = text[i:j].rstrip("\n") + "\n"
    text = text[:i] + text[j:]

    end = text.index("<%end%>") + len("<%end%>")
    text = text[:end] + "\n\n" + block + text[end:]

    if LOOP_ROW_HEAD not in text:
        raise RuleError("%s: component row anchor changed" % APP_VERSION_HTM)
    text = text.replace(
        LOOP_ROW_HEAD,
        LOOP_ROW_HEAD.replace('<div class="cbi-value">', '<div class="cbi-value app-version-row">'),
    )
    text = text.replace(
        PW_ROW_HEAD,
        PW_ROW_HEAD.replace('<div class="cbi-value">', '<div class="cbi-value app-version-row">'),
    )

    # move the version text into its own fixed, right-aligned column with 【 】,
    # matching the upstream release layout the user is used to
    for old, new in ((LOOP_LABEL_OLD, LOOP_LABEL_NEW), (PW_LABEL_OLD, PW_LABEL_NEW)):
        if old not in text:
            raise RuleError("%s: version row anchor changed: %r" % (APP_VERSION_HTM, old[:40]))
        text = text.replace(old, new, 1)

    if "passwall2-update-box" not in text.split("</style>", 1)[-1]:
        text = text.rstrip("\n") + "\n\n" + BOX_JS
    tree.save(APP_VERSION_HTM, text)
    tree.applied.append("fork_ui %s" % APP_VERSION_HTM)

    # 5. "restore default config" must not resurrect nodes from the template
    tree.sub(
        APP + "/luasrc/controller/passwall2.lua",
        "\tluci.sys.call('[ -f \"/usr/share/passwall2/0_default_config\" ] && "
        "cp -f /usr/share/passwall2/0_default_config /etc/config/passwall2')\n",
        "\t-- Restore the settings template, but never bring back the nodes it may contain:\n"
        "\t-- resetting must not resurrect demo or old node entries.\n"
        '\tlocal default_config = "/etc/passwall2_template.conf"\n'
        "\tif not fs.access(default_config) then\n"
        '\t\tdefault_config = "/usr/share/passwall2/0_default_config"\n'
        "\tend\n"
        "\tif fs.access(default_config) then\n"
        "\t\tlocal out, skip = {}, false\n"
        "\t\tfor line in io.lines(default_config) do\n"
        '\t\t\tif line:match("^config%s+nodes") then\n'
        "\t\t\t\tskip = true\n"
        '\t\t\telseif line:match("^config%s") then\n'
        "\t\t\t\tskip = false\n"
        "\t\t\tend\n"
        '\t\t\tif not skip and not line:match("^%s*option%s+node%s") then\n'
        "\t\t\t\tout[#out + 1] = line\n"
        "\t\t\tend\n"
        "\t\tend\n"
        '\t\tfs.writefile(c_config, table.concat(out, "\\n") .. "\\n")\n'
        "\tend\n",
    )

    # 4. readable log font, independent of the theme
    for rel in (LOG_HTM, SERVER_LOG_HTM):
        tree.sub(
            rel,
            '</script>\n<fieldset class="cbi-section" id="_log_fieldset">',
            LOG_STYLE,
        )


def main():
    if len(sys.argv) != 2:
        print("usage: strip_xray.py <repo-root>", file=sys.stderr)
        return 2
    tree = Tree(sys.argv[1])
    for rel in DELETE_FILES:
        tree.remove_file(rel)
    for rel in LUA_FILES:
        if tree.exists(rel):
            prune_lua_arms(tree, rel)
    rules_lua(tree)
    rules_html(tree)
    rules_api(tree)
    rules_strings(tree)
    rules_app_sh(tree)
    rules_meta(tree)
    rules_po(tree)
    rules_fork_ui(tree)
    print("applied %d operations" % len(tree.applied))
    return 0


if __name__ == "__main__":
    sys.exit(main())
