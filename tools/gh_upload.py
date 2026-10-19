#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本 Tweak 工程整仓推到 GitHub(本机无 git / gh,用系统 curl 打 REST API)。

    python tools/gh_upload.py --repo liudubin/douyin-sparks-helper --private \
        --token-file C:/Users/12936/Downloads/gh_token.txt --tag v2.16.0

    python tools/gh_upload.py --dry-run        # 不联网,只列出会推哪些文件

原理:blob(逐个文件) -> tree(整棵树,不带 base_tree = 全量替换) -> commit ->
移动 refs/heads/main。所以本地删掉的旧文件不会残留在远端。
token 从 --token-file 或环境变量 GITHUB_TOKEN 读取,脚本自己绝不打印它。

需要的 PAT 权限(fine-grained):Contents: R/W;要建仓再加 Administration: R/W。
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", ".theos", "packages", "out", "objc_dump", "__pycache__", "node_modules"}
SKIP_SUFFIX = {".deb", ".ddeb", ".o", ".dylib", ".a", ".pyc"}


def log(msg):
    print(msg, flush=True)


def collect():
    files = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            p = Path(dirpath) / fn
            if p.suffix.lower() in SKIP_SUFFIX:
                continue
            rel = p.relative_to(ROOT).as_posix()
            mode = "100755" if p.suffix == ".sh" else "100644"
            files.append((rel, p, mode))
    files.sort()
    return files


class Api:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, payload=None):
        """返回 (status, data)。body 与状态码分开取(curl -o + -w),避免解析歧义。"""
        fd_out, body_path = tempfile.mkstemp(suffix=".out")
        os.close(fd_out)
        args = ["curl", "-sS", "-X", method]
        req = None
        if payload is not None:
            fd, req = tempfile.mkstemp(suffix=".json")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False)
            args += ["-H", "Content-Type: application/json", "--data-binary", "@" + req]
        args += ["-H", "Accept: application/vnd.github+json",
                 "-H", "Authorization: Bearer " + self.token,
                 "-H", "X-GitHub-Api-Version: 2022-11-28",
                 "-o", body_path, "-w", "%{http_code}",
                 "https://api.github.com" + path]
        try:
            # 这条网络链路偶发 schannel 握手失败(curl 35)/连接重置(56),重试几次都能过
            r = None
            for attempt in range(5):
                r = subprocess.run(args + ["--retry", "3", "--retry-all-errors",
                                           "--retry-delay", "2"],
                                   capture_output=True, text=True,
                                   encoding="utf-8", errors="replace")
                code = int((r.stdout or "0").strip() or 0) if r.returncode == 0 else 0
                if r.returncode == 0 and code not in (0, 502, 503, 504):
                    break
                time.sleep(2 + attempt)
            if r is None or r.returncode != 0:
                sys.exit("curl 失败(%d): %s" % (r.returncode if r else -1,
                                                (r.stderr if r else "").strip()))
            code = int(r.stdout.strip() or 0)
            text = Path(body_path).read_text(encoding="utf-8", errors="replace")
            try:
                return code, json.loads(text) if text.strip() else {}
            except ValueError:
                return code, text
        finally:
            for f in (body_path, req):
                if f and os.path.exists(f):
                    os.unlink(f)


def die(msg, code, data):
    log("✗ %s (HTTP %s)" % (msg, code))
    log(json.dumps(data, ensure_ascii=False, indent=2)[:1200] if not isinstance(data, str) else data[:1200])
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", help="owner/name")
    ap.add_argument("--private", action="store_true", help="仓库不存在时按私有创建")
    ap.add_argument("--token-file")
    ap.add_argument("--tag")
    ap.add_argument("--message", default="")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    files = collect()
    total = sum(p.stat().st_size for _, p, _ in files)
    log("待推送 %d 个文件,合计 %d 字节" % (len(files), total))
    if a.dry_run:
        for rel, p, _ in files:
            log("  %-46s %7d" % (rel, p.stat().st_size))
        return 0

    if not a.repo:
        sys.exit("缺 --repo owner/name")
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if a.token_file:
        token = Path(a.token_file).read_text(encoding="utf-8").strip()
    if not token:
        sys.exit("缺 token:用 --token-file 或环境变量 GITHUB_TOKEN")
    if not token.startswith(("ghp_", "github_pat_", "gho_", "ghs_")):
        log("⚠️ token 前缀不像 GitHub PAT,继续尝试")

    api = Api(token)
    code, me = api.call("GET", "/user")
    if code != 200:
        die("token 无效或无权限", code, me)
    login = me.get("login")
    log("token 账号: %s" % login)

    owner, name = a.repo.split("/", 1)
    code, repo = api.call("GET", "/repos/%s/%s" % (owner, name))
    if code == 404:
        if owner != login:
            die("仓库 %s 不存在,且不属于 token 账号 %s" % (a.repo, login), code, repo)
        code, repo = api.call("POST", "/user/repos", {
            "name": name,
            "private": bool(a.private),
            "description": "抖音私信AI续火花助手 —— 适配抖音 40.7.0 (Theos Tweak)",
            "has_issues": True, "has_wiki": False, "auto_init": False,
        })
        if code not in (200, 201):
            die("建仓失败", code, repo)
        log("✓ 已新建仓库 %s(%s)" % (a.repo, "私有" if a.private else "公开"))
    elif code != 200:
        die("读仓库失败", code, repo)
    else:
        log("✓ 仓库已存在(%s),分支 %s" % ("私有" if repo.get("private") else "公开",
                                          repo.get("default_branch")))

    branch = repo.get("default_branch") or "main"
    code, ref = api.call("GET", "/repos/%s/%s/git/ref/heads/%s" % (owner, name, branch))
    if code != 200:
        # 全新空仓库的 Git 数据库还没初始化,直接建 blob 会 409 "Git Repository is empty."
        # (GET ref 在这种仓库上同样不回 200)。
        # 先用 Contents API 落一个占位文件把仓库点着,之后的全量 tree 会把它覆盖掉。
        boot = base64.b64encode(b"bootstrap\n").decode()
        code, r0 = api.call("PUT", "/repos/%s/%s/contents/.github-bootstrap" % (owner, name),
                            {"message": "chore: 初始化仓库", "content": boot})
        if code not in (200, 201):
            die("空仓库初始化失败", code, r0)
        log("✓ 空仓库已初始化")
        code, ref = api.call("GET", "/repos/%s/%s/git/ref/heads/%s" % (owner, name, branch))
    parents = [ref["object"]["sha"]] if code == 200 else []
    if parents:
        log("✓ 接在远端 %s 之上" % parents[0][:12])

    tree = []
    for i, (rel, p, mode) in enumerate(files, 1):
        b64 = base64.b64encode(p.read_bytes()).decode()
        code, blob = api.call("POST", "/repos/%s/%s/git/blobs" % (owner, name),
                              {"content": b64, "encoding": "base64"})
        if code not in (200, 201):
            die("上传 blob 失败: " + rel, code, blob)
        tree.append({"path": rel, "mode": mode, "type": "blob", "sha": blob["sha"]})
        log("  [%2d/%2d] blob %s" % (i, len(files), rel))

    code, new_tree = api.call("POST", "/repos/%s/%s/git/trees" % (owner, name),
                              {"tree": tree})
    if code not in (200, 201):
        die("建 tree 失败", code, new_tree)
    msg = a.message or ("适配抖音 40.7.0 (407019)\n\n" if a.tag else "sync\n") + \
        "\n".join(["- %s" % r for r, _, _ in files][:20])
    payload = {"message": msg, "tree": new_tree["sha"]}
    if parents:
        payload["parents"] = parents
    code, commit = api.call("POST", "/repos/%s/%s/git/commits" % (owner, name), payload)
    if code not in (200, 201):
        die("建 commit 失败", code, commit)
    sha = commit["sha"]
    log("✓ commit %s" % sha)

    if parents:
        code, r2 = api.call("PATCH", "/repos/%s/%s/git/refs/heads/%s" % (owner, name, branch),
                            {"sha": sha})
    else:
        code, r2 = api.call("POST", "/repos/%s/%s/git/refs" % (owner, name),
                            {"ref": "refs/heads/" + branch, "sha": sha})
    if code not in (200, 201):
        die("更新分支失败", code, r2)
    log("✓ 分支 %s -> %s" % (branch, sha[:12]))

    if a.tag:
        tpath = "/repos/%s/%s/git/refs/tags/%s" % (owner, name, a.tag)
        code, _ = api.call("GET", tpath)
        if code == 200:
            code, r3 = api.call("PATCH", tpath, {"sha": sha, "force": True})
        else:
            code, r3 = api.call("POST", "/repos/%s/%s/git/refs" % (owner, name),
                                {"ref": "refs/tags/" + a.tag, "sha": sha})
        if code not in (200, 201):
            die("打 tag 失败", code, r3)
        log("✓ tag %s" % a.tag)

    log("完成: https://github.com/%s/commit/%s" % (a.repo, sha))
    return 0


if __name__ == "__main__":
    sys.exit(main())
