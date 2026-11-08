#!/bin/bash
# Test iOS (simulator) hoặc Mac (MODE=mac, qua test-mac.sh) theo nhóm class.
# - Có tham số (vd -only-testing:CutCutTests/Foo) → chạy hẹp 1 lệnh như cũ.
# - Không tham số → build-for-testing 1 lần, rồi chạy bộ test theo NHÓM class (6 nhóm). Cả bộ trên máy CI mất hơn 60 phút
#   (trần 1 lệnh Bash), nên chạy tới ~45 phút thì dừng, in "CHƯA XONG", exit 75. Gõ lại đúng lệnh → chạy tiếp nhóm còn lại.
#   Tiến độ ở /tmp/ios-test-progress. ponytail: nhóm đã xanh không chạy lại dù code đổi sau đó; cần chắc thì xoá file này.
# Máy macOS free RAM ít: -jobs 3, không index, test tuần tự, DerivedData CHUNG /tmp/dd với lần build app chạy thật.
set -uo pipefail
# Trần thời gian mỗi lệnh xcodebuild: treo (sim không lên, test đứng) thì bị giết (exit 142) thay vì im 3 tiếng rồi bị watchdog huỷ job.
# ponytail: SIGALRM chỉ giết xcodebuild, tiến trình test con có thể sót lại; cần sạch hơn thì kill cả process group.
lim(){ perl -e 'alarm shift; exec @ARGV' "$@"; }
# MODE=mac (scripts/test-mac.sh): scheme CutCutMacTests trên macOS, build CutCutMacSpike trước, cùng cách chia nhóm.
# Máy CI không đăng nhập Apple ID → tắt ký app (CODE_SIGNING_ALLOWED=NO, #195). Chỉ là bản test, không phải bản phát hành.
if [ "${MODE:-ios}" = mac ]; then
  T=CutCutMacTests; X=(-project ios/CutCut/CutCut.xcodeproj -scheme CutCutMacTests -destination platform=macOS -derivedDataPath /tmp/dd-mac
     -jobs 3 COMPILER_INDEX_STORE_ENABLE=NO -parallel-testing-enabled NO -quiet CODE_SIGNING_ALLOWED=NO)
  [ $# -gt 0 ] && exec perl -e 'alarm shift; exec @ARGV' 3000 xcodebuild test "${X[@]}" "$@"
  lim 3000 xcodebuild build -project ios/CutCut/CutCut.xcodeproj -scheme CutCutMacSpike -destination platform=macOS -derivedDataPath /tmp/dd-mac \
    -jobs 3 COMPILER_INDEX_STORE_ENABLE=NO -quiet CODE_SIGNING_ALLOWED=NO || { echo "BUILD CutCutMacSpike ĐỎ"; exit 1; }
else
  udid=${SIM_UDID:-$(xcrun simctl list devices available -j \
    | jq -r '[.devices | to_entries[] | select(.key | test("iOS")) | .value[] | select(.name | test("^iPhone"))][-1].udid')}
  [ -n "$udid" ] && [ "$udid" != "null" ] || { echo "Không có simulator iPhone"; exit 1; }
  T=CutCutTests; X=(-project ios/CutCut/CutCut.xcodeproj -scheme CutCut -destination "id=$udid" -derivedDataPath /tmp/dd
     -jobs 3 COMPILER_INDEX_STORE_ENABLE=NO -parallel-testing-enabled NO -quiet)
  [ $# -gt 0 ] && exec perl -e 'alarm shift; exec @ARGV' 3000 xcodebuild test "${X[@]}" "$@"
fi

P=/tmp/${MODE:-ios}-test-progress; BUDGET=${IOS_TEST_BUDGET:-2700}; GROUPS_N=6; t0=$(date +%s); touch "$P"
lim 3000 xcodebuild build-for-testing "${X[@]}" || { echo "BUILD ĐỎ (hoặc treo quá 50 phút, exit 142)"; exit 1; }
classes=($(grep -rhoE 'class [A-Za-z0-9_]+ *: *XCTestCase' ios/CutCut/$T | awk '{print $2}' | tr -d ':' | sort -u))
n=${#classes[@]}; [ "$n" -gt 0 ] || { echo "Không thấy class test nào"; exit 1; }
for ((g = 0; g < GROUPS_N; g++)); do
  grep -qx "nhom$g OK" "$P" && continue
  if [ $(( $(date +%s) - t0 )) -gt "$BUDGET" ]; then
    left=$(( GROUPS_N - $(grep -c ' OK$' "$P") ))
    echo "CHƯA XONG: còn $left/$GROUPS_N nhóm test. Gõ lại đúng \$TEST_CMD để chạy tiếp (nhóm xanh không chạy lại)."; exit 75
  fi
  only=(); for ((i = g; i < n; i += GROUPS_N)); do only+=("-only-testing:$T/${classes[$i]}"); done
  echo "nhóm $((g + 1))/$GROUPS_N: ${#only[@]} class"
  sed -i '' "/^nhom$g /d" "$P"
  if lim 1500 xcodebuild test-without-building "${X[@]}" "${only[@]}" > "/tmp/${MODE:-ios}-test-nhom$g.log" 2>&1; then echo "nhom$g OK" >> "$P"
  else echo "nhom$g FAIL" >> "$P"; grep -q . "/tmp/${MODE:-ios}-test-nhom$g.log" || echo "(log rỗng: có thể treo quá 25 phút)"; echo "--- nhóm $((g + 1)) ĐỎ, log đủ: /tmp/${MODE:-ios}-test-nhom$g.log"; grep -E 'error|failed|FAIL' "/tmp/${MODE:-ios}-test-nhom$g.log" | tail -30; fi
done
if grep -q ' FAIL$' "$P"; then echo "ĐỎ: $(grep -c ' FAIL$' "$P") nhóm. Sửa xong gõ lại \$TEST_CMD (chỉ chạy lại nhóm đỏ)."; exit 1; fi
rm -f "$P"; echo "XANH toàn bộ $n class test ${MODE:-ios}"
