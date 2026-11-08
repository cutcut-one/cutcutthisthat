#!/bin/bash
# Hàm dùng chung cho runner — chỉ định nghĩa hàm, source không chạy gì.

# Nhãn bot:* → số bot (1 queenie, 2 ironman, 3 spiderman); rỗng nếu không có. Đầu vào: ",nhãn1,nhãn2,".
bot_no_from_labels() {
  case "$1" in *,bot:queenie,*) echo 1 ;; *,bot:ironman,*) echo 2 ;; *,bot:spiderman,*) echo 3 ;; esac
}
bot_name() { case "$1" in 1) echo "Captain Queenie" ;; 2) echo "Iron Man" ;; 3) echo "Spider Man" ;; *) echo "Runner" ;; esac; }
bot_label() { case "$1" in 1) echo bot:queenie ;; 2) echo bot:ironman ;; 3) echo bot:spiderman ;; esac; }

# Chạy lệnh, stdout → outfile; outfile không lớn thêm trong <idle> giây thì giết cả nhóm tiến trình, trả 124.
# Dùng: run_with_idle_kill <idle_giây> <outfile> -- <lệnh...>. perl setpgrp vì macOS không có setsid.
run_with_idle_kill() {
  local idle=$1 out=$2; shift 3
  : > "$out"
  perl -e 'eval { setpgrp(0,0) }; exec @ARGV or die' "$@" >> "$out" &
  local pid=$! last=0 size step=$(( idle / 3 )); [ "$step" -gt 60 ] && step=60; [ "$step" -lt 1 ] && step=1
  local quiet=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$step"
    size=$(wc -c < "$out" | tr -d ' ')
    if [ "$size" != "$last" ]; then last=$size; quiet=0; else quiet=$(( quiet + step )); fi
    if [ "$quiet" -ge "$idle" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null; return 124
    fi
  done
  wait "$pid"
}

# Tin /giao hợp lệ (đúng chat + topic, có nội dung) từ JSON getUpdates → mỗi tin 1 dòng JSON.
tg_parse_giao() {
  jq -c --arg c "$2" --arg t "$3" '.result[] | .update_id as $u | .message // empty
    | select((.chat.id|tostring) == $c and ((.message_thread_id // "")|tostring) == $t)
    | select((.text // "") | test("^/giao(@[A-Za-z0-9_]+)?(\\s|$)"))
    | {key: "tg:\(.chat.id):\(.message_id)", msg_id: .message_id, update_id: $u, date: .date,
       from: ([.from.first_name, .from.last_name] | map(select(.)) | join(" ")),
       text: (.text | sub("^/giao(@[A-Za-z0-9_]+)?\\s*"; "") | sub("\\s+$"; ""))}
    | select(.text != "")' "$1"
}
tg_max_update_id() { jq -r '[.result[].update_id] | max // empty' "$1"; }

# Kế hoạch tách việc hợp lệ: nền tảng đã biết, mỗi issue con có "## Task" với ≥1 ô "- [ ]" và "## Xong khi".
validate_plan() {
  jq -e '(.children | type == "array") and all(.children[];
    (.platform | IN("ios","android","mac","windows","linux"))
    and (.body | test("## Task") and test("- \\[ \\]") and test("## Xong khi"))
    and (.model | IN("opus","sonnet","haiku")))' "$1" >/dev/null 2>&1
}
# Bot ít việc nhất theo {"1":n,"2":n,"3":n}; hoà thì ưu tiên 2, 3 rồi 1 (Queenie là vợ kiêm sếp của Iron Man + Spider Man).
pick_bot() { jq -r '. as $c | ["2","3","1"] | min_by($c[.] // 0)' <<<"$1"; }
# Issue con xếp sao cho nền tảng được chờ (depends_on) tạo trước — để biết số # mà ghi "Chờ: #a".
order_children() {
  jq -c '.children as $c | [$c[] | .platform] as $all
    | def lvl($p; $d): if $d > 5 then 0 else ([$c[] | select(.platform == $p) | .depends_on[]? | select(IN($all[])) | 1 + lvl(.; $d + 1)] | max // 0) end;
    $c | map(. + {lvl: lvl(.platform; 0)}) | sort_by(.lvl) | .[] | del(.lvl)' "$1"
}

# Số issue phải chờ, từ dòng "Chờ: #12, #15" trong body.
blocked_by() { grep -m1 '^Chờ: ' <<<"$1" | grep -o '#[0-9]*' | tr -d '#'; }
# Nhắc hàng chờ: queue_alert <đang chờ> <đang chạy> <state json> <epoch> → dòng 1 low|idle|none, dòng 2 state mới.
# low: chờ ≤ 1, đã từng > 1 (armed), cách lần nhắc trước ≥ 3 giờ. idle: hết sạch, nhắc 1 lần tới khi có việc lại.
queue_alert() {
  jq -r --argjson w "$1" --argjson r "$2" --argjson now "$4" '
    (.last // 0) as $last | (.armed // true) as $armed | (.idle_sent // false) as $idle |
    if $w > 1 then ["none", {last: $last, armed: true, idle_sent: false}]
    elif $w == 0 and $r == 0 then
      if $idle then ["none", .] else ["idle", {last: $now, armed: false, idle_sent: true}] end
    elif $armed and ($now - $last) >= 10800 then ["low", {last: $now, armed: false, idle_sent: false}]
    else ["none", {last: $last, armed: $armed, idle_sent: false}] end
    | .[0], (.[1] | tojson)' <<<"$3"
}

# Issue #n được coi là xong để issue khác bắt đầu: PR nhánh ci/issue-n đã MERGE vào main (code có thật trên main);
# không có PR (làm tay) thì issue đã đóng. dep_done <repo> <n>, exit 0 = xong.
dep_done() {
  # Có PR (gốc hoặc ci/issue-N-rebase thay PR gốc bị đóng vì xung đột) → xong khi 1 trong 2 đã MERGED.
  local st; st=$( { gh pr view "ci/issue-$2" -R "$1" --json state -q .state; gh pr view "ci/issue-$2-rebase" -R "$1" --json state -q .state; } 2>/dev/null || true)
  if [ -n "$st" ]; then grep -qx MERGED <<<"$st"; else [ "$(gh issue view "$2" -R "$1" --json state -q .state 2>/dev/null)" = CLOSED ]; fi
}
# Còn phải chờ issue nào (in số, rỗng = được làm). blocked_open <repo> <body>
blocked_open() { local b; for b in $(blocked_by "$2"); do dep_done "$1" "$b" || echo "$b"; done; }
# Tin /giao trống (quên ghi việc) đúng chat + topic → in message_id để nhắc cách dùng.
tg_parse_giao_empty() {
  jq -r --arg c "$2" --arg t "$3" '.result[] | .message // empty
    | select((.chat.id|tostring) == $c and ((.message_thread_id // "")|tostring) == $t)
    | select((.text // "") | test("^/giao(@[A-Za-z0-9_]+)?\\s*$")) | .message_id' "$1"
}

# Nhánh gốc của issue (dòng "Nhánh gốc: desktop/main"); mặc định main. Chỉ nhận tên nhánh an toàn [A-Za-z0-9._/-], không "..".
base_branch() {
  local b; b=$(grep -m1 '^Nhánh gốc: ' <<<"$1" | sed 's/^Nhánh gốc: *//; s/[[:space:]]*$//')
  if [[ "$b" =~ ^[A-Za-z0-9._/-]+$ && "$b" != *..* ]]; then echo "$b"; else echo main; fi
}

# Lệnh duyệt đề xuất trong topic: "/duyet 101 #103", "/bo 102" → {"cmd":"duyet|bo","nums":[..],"msg_id":N}. Bỏ lệnh không có số.
tg_parse_cmd() {
  jq -c --arg c "$2" --arg t "$3" '.result[] | .message // empty
    | select((.chat.id|tostring) == $c and ((.message_thread_id // "")|tostring) == $t)
    | (.text // "") as $x | select($x | test("^/(duyet|bo)(@[A-Za-z0-9_]+)?(\\s|$)"))
    | {cmd: ($x | capture("^/(?<c>duyet|bo)").c), nums: [$x | scan("#?([0-9]+)") | .[0] | tonumber], msg_id: .message_id}
    | select(.nums | length > 0)' "$1"
}

# Hạn mức phiên 5 giờ của 1 tài khoản Claude (0..1), đọc header anthropic-ratelimit-unified-5h-utilization từ 1 lượt gọi
# siêu nhỏ (haiku, 1 token). Không đọc được → in rỗng. usage_5h <oauth token>
usage_5h() { quota_hdrs "$1" | awk -F': *' '$1=="anthropic-ratelimit-unified-5h-utilization"{print $2}'; }
# Header hạn mức (chữ thường) của 1 lượt gọi siêu nhỏ. quota_json <token> → {"h5":0.4,"d7":0.2,"reset5":epoch,"reset7":epoch} (thiếu thì null).
quota_json() { quota_hdrs "$1" | awk -F': *' '
  $1=="anthropic-ratelimit-unified-5h-utilization"{h=$2} $1=="anthropic-ratelimit-unified-7d-utilization"{d=$2}
  $1=="anthropic-ratelimit-unified-5h-reset"{r=$2} $1=="anthropic-ratelimit-unified-7d-reset"{r7=$2}
  END{printf "{\"h5\":%s,\"d7\":%s,\"reset5\":%s,\"reset7\":%s}\n", (h==""?"null":h), (d==""?"null":d), (r==""?"null":r), (r7==""?"null":r7)}'; }
quota_hdrs() {
  curl -s -o /dev/null -D - --max-time 20 https://api.anthropic.com/v1/messages \
    -H "Authorization: Bearer $1" -H "anthropic-version: 2023-06-01" -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
    -d '{"model":"claude-haiku-5-5","max_tokens":1,"system":"You are Claude Code, Anthropic'"'"'s official CLI for Claude.","messages":[{"role":"user","content":"hi"}]}' 2>/dev/null \
    | tr -d '\r' | awk -F': *' '{ $1 = tolower($1); print $1 ": " $2 }'
}
# Tài khoản phải nghỉ (exit 0) khi:
#  - giờ hành chính VN (7h–18h) và đã dùng ≥85% phiên 5h → chừa hạn mức cho owner; hoặc
#  - bất kể giờ: đã dùng ≥85% hạn mức 7 ngày mà còn hơn 3 ngày mới reset → khỏi đốt sạch tuần.
# Không đọc được hạn mức thì cho chạy (fail-open).
# peak_paused <oauth token> [giờ VN] [h5] [d7] [reset7 epoch] — có từ 3 tham số thì dùng số truyền vào, không gọi API.
PEAK_FROM=7; PEAK_TO=18; PEAK_PCT=0.85; WEEK_PCT=0.85; WEEK_DAYS=3
peak_paused() {
  local h u d r q
  if [ $# -ge 3 ]; then u=$3; d=${4:-}; r=${5:-}
  else q=$(quota_json "$1"); u=$(jq -r '.h5 // empty' <<<"$q"); d=$(jq -r '.d7 // empty' <<<"$q"); r=$(jq -r '.reset7 // empty' <<<"$q"); fi
  if [ -n "$d" ] && [ -n "$r" ] && awk -v d="$d" -v p="$WEEK_PCT" -v r="$r" -v n="$(date +%s)" -v k="$WEEK_DAYS" 'BEGIN{exit !(d >= p && r - n > k * 86400)}'; then return 0; fi
  h=${2:-$(TZ=Asia/Ho_Chi_Minh date +%H)}; h=$((10#$h))
  [ "$h" -ge "$PEAK_FROM" ] && [ "$h" -lt "$PEAK_TO" ] || return 1
  [ -n "$u" ] || return 1
  awk -v u="$u" -v p="$PEAK_PCT" 'BEGIN{exit !(u >= p)}'
}

# Nút bấm dưới tin kẹt (cuu:N / lai:N / bo:N), đúng chat → {"id","act","n","msg_id"}.
tg_parse_cb() {
  jq -c --arg c "$2" '.result[] | .callback_query // empty | select((.message.chat.id|tostring) == $c)
    | (.data // "" | capture("^(?<act>cuu|lai|bo):(?<n>[0-9]+)$")) as $d
    | {id: .id, act: $d.act, n: ($d.n|tonumber), msg_id: .message.message_id}' "$1"
}
# Gợi ý gỡ kẹt: trả lời (reply) tin "#N … kẹt" của bot, hoặc "/goiy N <gợi ý>", đúng chat + topic → {"n","text","msg_id","from"}.
tg_parse_hint() {
  jq -c --arg c "$2" --arg t "$3" '.result[] | .message // empty
    | select((.chat.id|tostring) == $c and ((.message_thread_id // "")|tostring) == $t)
    | (.text // "") as $x | (.reply_to_message // {}) as $r
    | (if ($x | test("^/goiy(@[A-Za-z0-9_]+)?\\s+#?[0-9]+\\s+\\S"))
         then ($x | capture("^/goiy(@[A-Za-z0-9_]+)?\\s+#?(?<n>[0-9]+)\\s+(?<t>[\\s\\S]+)$") | {n: (.n|tonumber), text: .t})
       elif ($r.from.is_bot == true) and (($r.text // "") | test("kẹt")) and ($x | test("^[^/]"))
         then {n: ($r.text | capture("#(?<n>[0-9]+)").n | tonumber), text: $x}
       else empty end)
    + {msg_id: .message_id, from: ([.from.first_name, .from.last_name] | map(select(.)) | join(" "))}' "$1"
}
