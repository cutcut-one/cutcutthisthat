#!/usr/bin/env bash
# Đẩy MỌI dòng KEY=giá trị trong file env (ngoài repo) lên secret của repo GitHub, rồi bật workflow chạy nền.
# Ô trống thì hỏi (gõ ẩn); Enter = bỏ qua. Không bao giờ in giá trị.
# Dùng:
#   bash scripts/setup-secrets.sh                                   # CutCut → cutcut-one/cutcutthisthat
#   bash scripts/setup-secrets.sh <owner/repo> <file.env>           # dự án khác (vd uniscore)
set -euo pipefail
REPO=${1:-cutcut-one/cutcutthisthat}
ENV_FILE=${2:-$HOME/.config/cutcut/runner-secrets.env}
[ -f "$ENV_FILE" ] || { echo "Không thấy $ENV_FILE"; exit 1; }
gh api "repos/$REPO" >/dev/null || { echo "Repo $REPO chưa có"; exit 1; }

NAMES=$(grep -oE '^[A-Z][A-Z0-9_]*=' "$ENV_FILE" | tr -d =)
set -a; . "$ENV_FILE"; set +a

for n in $NAMES; do
  v=${!n:-}
  [ -n "$v" ] || { read -rsp "$n (Enter = bỏ qua): " v || true; echo; }
  [ -n "$v" ] || { echo "– $n bỏ qua"; continue; }
  printf '%s' "$v" | gh secret set "$n" -R "$REPO" >/dev/null && echo "✓ $n"
done

# Tên cũ workflow còn đọc (= bot 1).
for n in CLAUDE_CODE_OAUTH_TOKEN TG_BOT_TOKEN; do
  v1=$n'_1'; [ -n "${!v1:-}" ] && printf '%s' "${!v1}" | gh secret set "$n" -R "$REPO" >/dev/null && echo "✓ $n (= _1)"
done

for w in dispatch intake digest morning; do gh workflow enable "$w.yml" -R "$REPO" 2>/dev/null && echo "▶ bật $w" || true; done
echo "Xong. Kiểm: gh secret list -R $REPO"
