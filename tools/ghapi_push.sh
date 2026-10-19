#!/usr/bin/env bash
# gh api 推送提交(绕过 git 传输;大文件走 --input JSON,避开命令行长度限制)
set -e
REPO=liudubin/douyin-sparks-helper
cd /d/zhipu/douyin-sparks-helper

REMOTE_SHA=$(gh api repos/$REPO/branches/main --jq .commit.sha)
BASE_SHA=$(git rev-parse HEAD~1)
if [ "$REMOTE_SHA" != "$BASE_SHA" ]; then
  echo "远端基线与本地父提交不一致: $REMOTE_SHA vs $BASE_SHA" >&2
  exit 1
fi

FILES=$(git diff --name-only $BASE_SHA HEAD)
BASE_TREE=$(gh api repos/$REPO/git/commits/$REMOTE_SHA --jq .tree.sha)

TMP=$(mktemp -d)
ENTRIES="$TMP/entries.json"
echo "[" > "$ENTRIES"
first=1
for f in $FILES; do
  base64 -w0 "$f" > "$TMP/content.b64"
  python - "$TMP/blob.json" "$TMP/content.b64" <<'PY'
import json, sys
b64 = open(sys.argv[2]).read().strip()
open(sys.argv[1], "w").write(json.dumps({"content": b64, "encoding": "base64"}))
PY
  BLOB_SHA=$(gh api repos/$REPO/git/blobs --input "$TMP/blob.json" --jq .sha)
  echo "  blob $f -> $BLOB_SHA"
  [ $first -eq 1 ] || echo "," >> "$ENTRIES"
  first=0
  python - "$ENTRIES" "$f" "$BLOB_SHA" <<'PY'
import json, sys
with open(sys.argv[1], "a") as fp:
    fp.write(json.dumps({"path": sys.argv[2], "mode": "100644", "type": "blob", "sha": sys.argv[3]}, ensure_ascii=False))
PY
done
echo "]" >> "$ENTRIES"

python - "$TMP/tree.json" "$BASE_TREE" "$ENTRIES" <<'PY'
import json, sys
base = sys.argv[2]
entries = json.load(open(sys.argv[3], encoding="utf-8"))
open(sys.argv[1], "w").write(json.dumps({"base_tree": base, "entries": entries}))
PY
NEW_TREE=$(gh api repos/$REPO/git/trees --input "$TMP/tree.json" --jq .sha)
echo "new tree: $NEW_TREE"

MSG=$(git log -1 --pretty=%B)
python - "$TMP/commit.json" "$MSG" "$NEW_TREE" "$REMOTE_SHA" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({
    "message": sys.argv[2],
    "tree": sys.argv[3],
    "parents": [sys.argv[4]],
}, ensure_ascii=False))
PY
NEW_COMMIT=$(gh api repos/$REPO/git/commits --input "$TMP/commit.json" --jq .sha)
echo "new commit: $NEW_COMMIT"

gh api -X PATCH repos/$REPO/git/refs/heads/main -f sha=$NEW_COMMIT >/dev/null
gh api repos/$REPO/git/refs -f ref=refs/tags/v2.0.1 -f sha=$NEW_COMMIT >/dev/null 2>&1 || \
  gh api -X PATCH repos/$REPO/git/refs/tags/v2.0.1 -f sha=$NEW_COMMIT >/dev/null
rm -rf "$TMP"
echo "DONE main=$NEW_COMMIT tag=v2.0.1"
