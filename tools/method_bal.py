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
mode = 0
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
for idx, line in enumerate(code.split("\n"), 1):
    bal += line.count("[") - line.count("]")
    ls = line.strip()
    if (ls.startswith("- (") or ls.startswith("+ (")) and bal != 0:
        print(f"method decl at stripped-line {idx} with bal={bal}: {ls[:60]}")
print("done")
