#!/bin/bash
# Làm trọn 1 issue trên runner đang chạy: nhánh → các vòng Claude → báo cáo (PR, comment, ảnh, label).
# Gọi lặp cho nhiều issue trong cùng 1 job (máy ảo/Xcode/plugin chỉ dựng 1 lần).
# Chạy trong thư mục vibecut. Cần env: ISSUE REPO PLATFORM DEADLINE TEST_CMD GITHUB_RUN_ID.
# Log PUBLIC: chỉ in số issue + đếm task.
set -uo pipefail
export BRANCH=ci/issue-$ISSUE
left() { gh issue view "$ISSUE" -R "$REPO" --json body -q .body | grep -c -- '- \[ \]' || true; }
echo "$ISSUE" > /tmp/current_issue
t0=$(date +%s)

# Nhánh sạch cho issue này: tiếp nhánh cũ nếu có, không thì từ main.
git reset -q --hard; git clean -fdq
# Nhánh gốc theo dòng "Nhánh gốc: X" trong issue (dự án lớn như desktop/main), mặc định main.
source ../runner/scripts/lib.sh
export BASE; BASE=$(base_branch "$(gh issue view "$ISSUE" -R "$REPO" --json body -q .body)")
if git fetch -q --depth 1 origin "$BRANCH" 2>/dev/null; then git checkout -qB "$BRANCH" FETCH_HEAD
else git fetch -q --depth 1 origin "$BASE" && git checkout -qB "$BRANCH" FETCH_HEAD; fi
rm -rf /tmp/shots ../claude-*.json ../claude-*.jsonl ../claude.err; mkdir -p /tmp/shots
before=$(left)
# Gắn lại ci-running mỗi lần vào: job đổi tài khoản (hết hạn mức) chạy lại script trên CÙNG issue sau khi lượt trước đã gỡ nhãn → không gắn thì dispatch mở job trùng.
gh issue edit "$ISSUE" -R "$REPO" --add-label ci-running >/dev/null || true
title=$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)
tg() { bash ../runner/scripts/tg.sh "$@"; }
source ../runner/scripts/lib.sh
idle=0

# Chọn model (công thức ở README): label model:* thắng; bug/perf → opus; tối thiểu sonnet (haiku làm worker không theo prompt: hỏi lại "task là gì" rồi thoát — #92).
# Loop không ra kết quả → nâng từng bậc (xem dưới vòng lặp).
labels=",$(gh issue view "$ISSUE" -R "$REPO" --json labels -q '[.labels[].name] | join(",")'),"
case "$labels" in
  *,model:opus,*) MODEL=opus ;; *,model:sonnet,*) MODEL=sonnet ;; *,model:haiku,*) MODEL=sonnet ;;
  *,bug,*|*,perf,*) MODEL=opus ;;
  *,documentation,*|*,i18n,*) MODEL=sonnet ;;
  *) MODEL=sonnet ;;
esac

# Vòng Claude: dừng sớm mà còn task + còn giờ → phiên MỚI làm tiếp.
# ponytail: thôi khi 1 vòng không có commit lẫn tick nào (task còn lại đều BỎ QUA / bế tắc hạ tầng).
round=0
while :; do
  # 7h–18h mà acc đã dùng ≥85% phiên 5h → nghỉ như hết hạn mức (job nhường acc khác / dừng), chừa cho owner.
  if peak_paused "$CLAUDE_CODE_OAUTH_TOKEN"; then echo "acc #${BOT_NO:-?} chạm ngưỡng nghỉ (85% phiên 5h giờ hành chính, hoặc 85% tuần còn >3 ngày mới reset) → nghỉ"; QUOTA=1; PEAK=1; break; fi
  round=$((round + 1)); c0=$(git rev-list --count HEAD); l0=$(left)
  # Output chỉ ghi ra file — KHÔNG in console.
  # Watchdog trong job: Claude không in gì 65 phút (> trần 1 lệnh Bash 60 phút) → giết, mở phiên mới.
  # Bỏ chặn quyền nhưng CẤM CỨNG lệnh không đảo ngược được: push main/force, merge PR, gọi API/curl ra ngoài, đụng secret.
  run_with_idle_kill 3900 "../claude-$round.jsonl" -- claude -p "$(cat ../runner/prompt.md)${NUDGE:+$'\n\n'$NUDGE}" --model "$MODEL" \
    --dangerously-skip-permissions --add-dir /tmp --output-format stream-json --verbose \
    --disallowedTools "Bash(git push origin main*)" "Bash(git push origin HEAD:main*)" "Bash(git push --force*)" \
      "Bash(git push -f*)" "Bash(git push origin desktop/*)" "Bash(git push origin HEAD:desktop/*)" "Bash(gh pr merge*)" "Bash(gh api*)" "Bash(gh secret*)" "Bash(gh repo*)" "Bash(curl*)" \
      "Bash(wget*)" "Bash(env*)" "Bash(printenv*)" ScheduleWakeup Monitor CronCreate TaskOutput 2>> ../claude.err
  rc=$?; grep '"type":"result"' "../claude-$round.jsonl" | tail -1 > "../claude-$round.json"
  l1=$(left); echo "issue #$ISSUE vòng $round ($MODEL): exit=$rc còn $l1 task"
  if [ "$rc" = 124 ]; then
    idle=$(( ${idle:-0} + 1 )); echo "im 65 phút, khởi động lại ($idle/3)"
    [ "$idle" -ge 3 ] && break
    [ $(( DEADLINE - $(date +%s) )) -lt 1200 ] && break
    continue
  fi
  # Hết hạn mức Claude: dừng hẳn, KHÔNG coi là bế tắc (giữ ci-run cho lượt sau).
  # Chỉ xét khi phiên kết thúc LỖI (is_error / không ra JSON), kẻo chữ "429" trong tóm tắt bình thường bị bắt nhầm.
  if ! jq -e '.is_error == false' "../claude-$round.json" >/dev/null 2>&1 \
     && cat "../claude-$round.json" <(tail -n 3 "../claude-$round.jsonl") ../claude.err 2>/dev/null | grep -qiE 'usage limit|limit reached|rate.?limit|overloaded'; then QUOTA=1; break; fi
  [ "$l1" = 0 ] && break
  [ $(( DEADLINE - $(date +%s) )) -lt 1200 ] && break
  # Loop không ra kết quả → nâng 1 bậc haiku → sonnet → opus. Ba trường hợp của 1 vòng không tick thêm ô nào:
  #  - Claude báo "CẦN-MODEL-MẠNH" (sửa 5 lần cùng lỗi vẫn đỏ), hoặc có commit mà vẫn không tick → nâng model.
  #  - Không commit, không báo gì → task còn lại đều BỎ QUA (hạ tầng/cần owner) → dừng, nâng model vô ích.
  #  Ở opus mà 2 vòng liền không tick → bỏ.
  if [ "$l1" = "$l0" ]; then
    if jq -r '.result // ""' "../claude-$round.json" 2>/dev/null | grep -q 'CẦN-MODEL-MẠNH' \
       || [ "$(git rev-list --count HEAD)" != "$c0" ]; then
      case "$MODEL" in
        haiku) MODEL=sonnet ;; sonnet) MODEL=opus ;;
        opus) stuck=$(( ${stuck:-0} + 1 )); [ "$stuck" -ge 2 ] && break ;;
      esac
      echo "issue #$ISSUE: loop không ra kết quả → $MODEL"
    elif [ "${nudged:-0}" = 0 ]; then
      # Phiên dừng giữa chừng không commit gì (hỏi lại "task là gì", "chờ chạy nền xong"…) → nhắc 1 lần rồi mới coi là kẹt.
      nudged=1; echo "issue #$ISSUE: phiên dừng sớm không làm gì → nhắc làm tiếp"
      NUDGE="LƯU Ý: phiên trước của bạn DỪNG GIỮA CHỪNG mà không commit gì. Trả lời cuối của nó: \"$(jq -r '.result // ""' "../claude-$round.json" 2>/dev/null | head -c 600)\". Không ai trả lời câu hỏi và không có gì chạy nền để chờ — tự đọc issue #$ISSUE rồi LÀM TIẾP ngay, chạy lệnh THẲNG và chờ kết quả."
    else break; fi
  else stuck=0; NUDGE=""; fi
done

# Báo cáo.
git push -q origin "HEAD:$BRANCH" 2>/dev/null || true
pr=$(gh pr view "$BRANCH" -R "$REPO" --json url -q .url 2>/dev/null \
  || gh pr create -R "$REPO" --head "$BRANCH" --base "$BASE" --title "CI: issue #$ISSUE" --body "Closes #$ISSUE" 2>/dev/null || true)
summary=$(for f in ../claude-*.json; do jq -r '.result // empty' "$f" 2>/dev/null; done)
[ -n "$summary" ] || summary="Claude dừng không có tóm tắt (có thể hết hạn mức hoặc hết giờ). $(tail -c 400 ../claude.err 2>/dev/null)"

# Ảnh → nhánh mồ côi ci-shots của repo PRIVATE, nhúng vào comment.
shots=""
if ls /tmp/shots/*.png >/dev/null 2>&1; then
  dir="issue-$ISSUE/$GITHUB_RUN_ID"
  git worktree remove --force ../shots 2>/dev/null; rm -rf ../shots
  if git fetch -q --depth 1 origin ci-shots 2>/dev/null; then git worktree add -q ../shots FETCH_HEAD
  else git worktree add -q --detach ../shots && (cd ../shots && git checkout -q --orphan ci-shots && git rm -rfq .); fi
  mkdir -p "../shots/$dir" && cp /tmp/shots/*.png "../shots/$dir/"
  if (cd ../shots && git add -A && git -c core.hooksPath=/dev/null commit -qm "ảnh issue #$ISSUE" && git push -q origin HEAD:ci-shots); then
    for f in /tmp/shots/*.png; do
      n=$(basename "$f"); cap=$(cat "${f%.png}.md" 2>/dev/null)
      shots="$shots"$'\n\n'"**${cap:-$n}**"$'\n'"![$n](https://github.com/$REPO/blob/ci-shots/$dir/$n?raw=true)"
    done
    shots="$shots"$'\n\n'"📁 [Cả thư mục ảnh](https://github.com/$REPO/tree/ci-shots/$dir) · ảnh cũng gửi vào Telegram (app GitHub không hiện ảnh repo private)"
  fi
  # Ảnh repo private chỉ hiện trong trình duyệt đã đăng nhập → gửi thẳng album vào Telegram cho xem được mọi nơi.
  bash ../runner/scripts/tg-album.sh "📸 #$ISSUE — $title" /tmp/shots/*.png
fi
# Chi phí = tổng total_cost_usd mọi vòng (giá quy đổi API; gói thuê bao không trừ tiền thật) — dòng cố định để bảng xếp hạng đọc.
cost=$(jq -s 'map(.total_cost_usd // 0) | add // 0' ../claude-*.json 2>/dev/null || echo 0)
mins=$(( ( $(date +%s) - t0 ) / 60 ))
costline=$(LC_ALL=C printf 'CHI PHÍ: $%.2f | PHÚT: %d | VÒNG: %d | MODEL: %s' "${cost:-0}" "$mins" "$round" "$MODEL")
gh issue comment "$ISSUE" -R "$REPO" --body "**Runner** (${PLATFORM})${pr:+ — $pr}"$'\n\n'"$summary"$'\n\n'"$costline$shots" >/dev/null

l=$(left)
if [ "${QUOTA:-0}" = 1 ]; then ic="⏸"; st="hết hạn mức, tạm dừng"; elif [ "$l" = 0 ]; then ic="✅"; st="xong"; elif [ "$l" = "$before" ]; then ic="⚠️"; st="bị kẹt, cần mày xem"; else ic="🔄"; st="xong $((before - l))/$before task, lượt sau làm tiếp"; fi
# Chỉ báo Telegram khi KẸT (xong thì gom vào báo cáo sáng); tin ngắn, không file: trạng thái + điểm/chi phí; chỉ liệt kê task hỏng (chi tiết ở comment issue).
score=$(grep -m1 -E '^ĐIỂM:' <<<"$summary" | sed -E 's/ĐIỂM: *([0-9.]+\/10) *\| *TỰ TIN: *([0-9]+%)/⭐ \1 · 🎯 \2 · /')
bad=$(grep -E '^✘ Task' <<<"$summary" | head -5 | sed 's/^✘/❌/')
kb='[[{"text":"🧠 Queenie gỡ","callback_data":"cuu:'"$ISSUE"'"},{"text":"🔁 Chạy lại","callback_data":"lai:'"$ISSUE"'"},{"text":"🛑 Bỏ","callback_data":"bo:'"$ISSUE"'"}]]'
if [ "$ic" = "⚠️" ]; then tg --kb "$kb" "$ic **#$ISSUE $st** — $title"$'\n'"$score$(LC_ALL=C printf '💰 $%.2f · ⏱ %d′' "${cost:-0}" "$mins")${bad:+$'\n'$bad}"$'\n'"✍️ Hoặc trả lời tin này để gợi ý cách làm"
# Owner muốn biết ngay từng task xong (11/11): báo cả ✅ xong hẳn và 🔄 xong một phần.
elif [ "$ic" = "✅" ] || [ "$ic" = "🔄" ]; then tg "$ic **#$ISSUE $st** — $title"$'\n'"$score$(LC_ALL=C printf '💰 $%.2f · ⏱ %d′' "${cost:-0}" "$mins")${pr:+$'\n'"🔗 $pr"}${bad:+$'\n'$bad}"; fi
if [ "${QUOTA:-0}" = 1 ]; then
  gh issue comment "$ISSUE" -R "$REPO" --body "Runner: ${PEAK:+tài khoản đã dùng ≥85% phiên 5h trong giờ 7h–18h, }hết hạn mức Claude, dừng. Giữ \`ci-run\`, lượt sau làm tiếp." >/dev/null
elif [ "$l" = 0 ]; then gh issue close "$ISSUE" -R "$REPO" --comment "Xong hết task.${pr:+ PR: $pr}" >/dev/null
elif [ "$l" = "$before" ]; then
  # Không tick thêm ô nào → gỡ ci-run, kẻo bị nhặt lại đốt hạn mức vô ích.
  gh issue edit "$ISSUE" -R "$REPO" --remove-label ci-run >/dev/null || true
  gh issue comment "$ISSUE" -R "$REPO" --body "Runner: lượt này không xong thêm task nào nên đã gỡ \`ci-run\`. Xử lý chỗ vướng ở trên rồi gắn lại." >/dev/null
fi
gh issue edit "$ISSUE" -R "$REPO" --remove-label ci-running >/dev/null || true
rm -f /tmp/current_issue
echo "issue #$ISSUE: còn $l task"
[ "${QUOTA:-0}" = 1 ] && exit 3 || exit 0
