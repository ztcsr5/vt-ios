#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Swift 源码静态体检（v2，低噪音）。

抓的是"编译器才会暴露"的那几类：
1) 字符串对之间（引号外的代码区）出现裸中文 → 说明中文串里混了 ASCII 双引号，把字符串切断了
   例：Text("它是"服务端"：...")  → 中间 "服务端 两边的引号已经闭合，服务端 变成裸标识符
2) 每行 ASCII 双引号个数为奇数（字符串未闭合）
3) 字符串对之间出现全角标点
4) 全文 {} () [] 不平衡

合法的 Text("自检") 不会报，因为引号外没有中文。
"""
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "VTClient")
CJK = re.compile(r"[\u4e00-\u9fff]")
FULLWIDTH = "，：；（）【】《》？！“”‘’、"


def strip_line_comments_and_blocks(lines):
    """去掉 // 与 /* */ 注释，保留行号。字符串内的 // 不误伤。"""
    out = []
    in_block = False
    for idx, raw in enumerate(lines, 1):
        s = raw
        if in_block:
            if "*/" in s:
                in_block = False
                s = s.split("*/", 1)[1]
            else:
                out.append((idx, ""))
                continue
        if "/*" in s and "*/" not in s.split("/*", 1)[1]:
            in_block = True
            s = s.split("/*", 1)[0]
        # 逐字符扫描，字符串内部不看 //
        res, i, in_str = [], 0, False
        while i < len(s):
            ch = s[i]
            if in_str:
                if ch == "\\":
                    res.append(s[i:i + 2]); i += 2; continue
                if ch == '"':
                    in_str = False
                res.append(ch); i += 1; continue
            if ch == '"':
                in_str = True; res.append(ch); i += 1; continue
            if s.startswith("//", i):
                break
            res.append(ch); i += 1
        out.append((idx, "".join(res)))
    return out


def split_strings(line):
    """返回 [(kind, text)]，kind='code' 或 'str'。处理 \\" 与 \\( 插值。"""
    parts, buf, i, in_str = [], [], 0, False
    depth_interp = 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\" and i + 1 < len(line):
                nxt = line[i + 1]
                if nxt == "(":
                    depth_interp += 1
                buf.append(line[i:i + 2]); i += 2; continue
            if depth_interp > 0:
                if ch == ")":
                    depth_interp -= 1
                buf.append(ch); i += 1; continue
            if ch == '"':
                parts.append(("str", "".join(buf))); buf = []; in_str = False; i += 1; continue
            buf.append(ch); i += 1; continue
        else:
            if ch == '"':
                if buf:
                    parts.append(("code", "".join(buf))); buf = []
                in_str = True; i += 1; continue
            buf.append(ch); i += 1
    if buf:
        parts.append(("str" if in_str else "code", "".join(buf)))
    return parts


total = 0
files = sorted(f for f in os.listdir(ROOT) if f.endswith(".swift"))
for fn in files:
    text = open(os.path.join(ROOT, fn), encoding="utf-8").read()
    lines = strip_line_comments_and_blocks(text.split("\n"))
    issues = []

    for idx, s in lines:
        if not s.strip():
            continue
        if s.replace('\\"', "").count('"') % 2 == 1:
            issues.append((idx, "引号数为奇数（字符串未闭合）", s.strip()[:120]))
            continue
        parts = split_strings(s)
        # 只看 code 段里是否混进中文/全角标点
        for kind, seg in parts:
            if kind != "code":
                continue
            if CJK.search(seg):
                bad = CJK.search(seg).group(0)
                issues.append((idx, f"引号外出现裸中文 {bad!r}（中文串里混了 ASCII 双引号，字符串被切断）",
                               s.strip()[:120]))
                break
            fw = next((c for c in FULLWIDTH if c in seg), None)
            if fw:
                issues.append((idx, f"引号外出现全角标点 {fw!r}", s.strip()[:120]))
                break

    # 括号平衡
    flat = "\n".join(s for _, s in lines)
    no_str = "".join(seg for kind, seg in split_strings(flat) if kind == "code")
    for op, cl, name in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        d = no_str.count(op) - no_str.count(cl)
        if d:
            issues.append((0, f"{name}不平衡 {no_str.count(op)}/{no_str.count(cl)} (差 {d})", ""))

    if issues:
        print(f"\n### {fn}  ({len(issues)} 处)")
        for idx, msg, ctx in issues:
            print(f"  {'L%d' % idx if idx else '--':>6}  {msg}")
            if ctx:
                print(f"          {ctx}")
        total += len(issues)
    else:
        print(f"OK   {fn}")

print(f"\n合计 {total} 处")
sys.exit(0 if total == 0 else 1)
