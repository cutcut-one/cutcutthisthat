#!/usr/bin/env bash
# Đẩy toàn bộ secret của Runner lên repo GitHub, rồi bật lại các workflow chạy nền.
# Giá trị đọc từ file NGOÀI repo (mặc định ~/.config/cutcut/runner-secrets.env, chmod 600);
# ô nào trống thì hỏi (gõ ẩn). Không bao giờ in giá trị ra màn hình.
# Dùng: bash scripts/setup-secrets.sh [owner/repo]
set -euo pipefail
REPO=${1:-cutcut-one/Runner}
ENV_FILE=${RUNNER_SECRETS:-$HOME/.config/cutcut/runner-secrets.env}

NAMES=(
  CLAUDE_CODE_OAUTH_TOKEN_1 CLAUDE_CODE_OAUTH_TOKEN_2 CLAUDE_CODE_OAUTH_TOKEN_3  # `claude setup-token` mỗi tài khoản
  VIBECUT_PAT        # PAT fine-grained: repo nguyenphp/vibecut (contents, issues, PR, actions: read/write)
  PROJECT_TOKEN      # PAT classic repo+project, cho bảng users/nguyenphp/projects/1 (bỏ trống = bỏ qua)
  TG_BOT_TOKEN_1 TG_BOT_TOKEN_2 TG_BOT_TOKEN_3 TG_CHAT_ID TG_THREAD_ID
  TEVO_NEXUS_URL TEVO_NEXUS_USERNAME TEVO_NEXUS_PASSWORD
)
OPTIONAL=" PROJECT_TOKEN TG_THREAD_ID "

# Tạo file mẫu lần đầu.
if [ ! -f "$ENV_FILE" ]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  printf '%s=\n' "${NAMES[@]}" > "$ENV_FILE"; chmod 600 "$ENV_FILE"
  echo "Đã tạo $ENV_FILE — điền giá trị rồi chạy lại (hoặc chạy luôn để được hỏi từng ô)."
fi
set -a; . "$ENV_FILE"; set +a

# Nexus lấy sẵn từ ~/.gradle/gradle.properties nếu file env để trống.
GP=$HOME/.gradle/gradle.properties
gp() { [ -f "$GP" ] && grep -E "^$1=" "$GP" | head -1 | cut -d= -f2- || true; }
: "${TEVO_NEXUS_URL:=$(gp tevoNexusMavenUrl)}"
: "${TEVO_NEXUS_USERNAME:=$(gp tevoNexusUsername)}"
: "${TEVO_NEXUS_PASSWORD:=$(gp tevoNexusPassword)}"

for n in "${NAMES[@]}"; do
  v=${!n:-}
  if [ -z "$v" ]; then
    read -rsp "$n (Enter = bỏ qua): " v; echo
  fi
  if [ -z "$v" ]; then
    case "$OPTIONAL" in *" $n "*) echo "– $n bỏ qua";; *) echo "⚠ $n trống";; esac
    continue
  fi
  printf '%s' "$v" | gh secret set "$n" -R "$REPO" >/dev/null && echo "✓ $n"
done

# Tương thích tên cũ (workflow vẫn đọc 1 chỗ).
[ -n "${CLAUDE_CODE_OAUTH_TOKEN_1:-}" ] && printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN_1" | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$REPO" >/dev/null && echo "✓ CLAUDE_CODE_OAUTH_TOKEN (= _1)"
[ -n "${TG_BOT_TOKEN_1:-}" ] && printf '%s' "$TG_BOT_TOKEN_1" | gh secret set TG_BOT_TOKEN -R "$REPO" >/dev/null && echo "✓ TG_BOT_TOKEN (= _1)"

for w in dispatch intake digest morning; do gh workflow enable "$w.yml" -R "$REPO" 2>/dev/null && echo "▶ bật $w"; done
echo "Xong. Kiểm: gh secret list -R $REPO"
