import os
import sys
from pathlib import Path

# 本地诊断工具:输入经 realpath 规范化,只允许读取 D:\zhipu 目录内已存在的文件
ALLOWED_ROOT = os.path.realpath(r"D:\zhipu")
path = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else "")
if path != ALLOWED_ROOT and not path.startswith(ALLOWED_ROOT + os.sep):
    sys.exit("path outside allowed dir: " + path)
if not os.path.isfile(path):
    sys.exit("file not found: " + path)
s = Path(path).read_text(encoding="utf-8", errors="replace")
out = []
i = 0
n = len(s)
mode = 0  # 0 code 1 str 2 chr 3 line-comment 4 block-comment
while i < n:
    c = s[i]
    if mode == 0:
        if c == '"':
            mode = 1
        elif c == "'":
            mode = 2
        elif c == '/' and i + 1 < n and s[i + 1] == '/':
            mode = 3; i += 1
        elif c == '/' and i + 1 < n and s[i + 1] == '*':
            mode = 4; i += 1
        else:
            out.append(c)
    elif mode == 1:
        if c == '\\':
            i += 1
        elif c == '"':
            mode = 0
    elif mode == 2:
        if c == '\\':
            i += 1
        elif c == "'":
            mode = 0
    elif mode == 3:
        if c == '\n':
            mode = 0; out.append(c)
    elif mode == 4:
        if c == '*' and i + 1 < n and s[i + 1] == '/':
            mode = 0; i += 1
    i += 1
code = "".join(out)
bal = 0
lines = code.split("\n")
deep = False
for idx, line in enumerate(lines, 1):
    bal += line.count("[") - line.count("]")
    if bal > 2 and not deep:
        print("bal>2 first at line", idx, ":", line.strip()[:70])
        deep = True
if not deep:
    print("never >2")
print("final bracket bal:", bal)
marks = []
b2 = 0
for idx, line in enumerate(lines, 1):
    d = line.count("[") - line.count("]")
    if d:
        b2 += d
        marks.append((idx, b2, line.strip()[:60]))
for m in marks[-6:]:
    print(m)
bal = 0
firstneg = None
for idx, line in enumerate(lines, 1):
    bal += line.count("[") - line.count("]")
    if bal < 0 and firstneg is None:
        firstneg = idx
if firstneg:
    print("first negative at", firstneg)
