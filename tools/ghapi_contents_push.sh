#!/usr/bin/env bash
# gh api Contents API 逐文件推送(绕过 git 传输与 trees 接口)
set -e
REPO=liudubin/douyin-sparks-helper
cd /d/zhipu/douyin-sparks-helper
BASE_SHA=$(git rev-parse HEAD~1)

# 清理探针文件
PROBE_SHA=$(gh api repos/$REPO/contents/zz_probe.txt --jq .sha 2>/dev/null || true)
if [ -n "$PROBE_SHA" ]; then
  gh api -X DELETE repos/$REPO/contents/zz_probe.txt -f message=cleanup -f sha=$PROBE_SHA >/dev/null || true
  echo "probe cleaned"
fi

TMP=$(mktemp -d)
for f in $(git diff --name-only $BASE_SHA HEAD); do
  git show HEAD:"$f" | base64 -w0 > "$TMP/content.b64"
  OLD_SHA=$(gh api "repos/$REPO/contents/$f" --jq .sha 2>/dev/null || true)
  python - "$TMP/put.json" "$TMP/content.b64" "$f" "$OLD_SHA" <<'PY'
import json, sys
content = open(sys.argv[2]).read().strip()
body = {"message": "v2.0.1 push: " + sys.argv[3], "content": content, "branch": "main"}
if sys.argv[4]:
    body["sha"] = sys.argv[4]
open(sys.argv[1], "w").write(json.dumps(body))
PY
  RES=$(gh api -X PUT "repos/$REPO/contents/$f" --input "$TMP/put.json" --jq .commit.sha)
  echo "  pushed $f -> $RES"
done

# 在最终提交上打 tag
FINAL=$(gh api repos/$REPO/branches/main --jq .commit.sha)
python - "$TMP/tag.json" "$FINAL" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({"ref": "refs/tags/v2.0.1", "sha": sys.argv[2]}))
PY
gh api repos/$REPO/git/refs --input "$TMP/tag.json" >/dev/null 2>&1 && echo "tag created" || \
  { python - "$TMP/tag2.json" "$FINAL" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({"sha": sys.argv[2], "force": True}))
PY
    gh api -X PATCH repos/$REPO/git/refs/tags/v2.0.1 --input "$TMP/tag2.json" >/dev/null && echo "tag moved"; }
rm -rf "$TMP"
echo "DONE head=$FINAL"
