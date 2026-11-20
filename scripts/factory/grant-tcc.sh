#!/bin/bash
# Cấp sẵn quyền nhận dạng giọng nói + micro cho app (runner GitHub tắt SIP nên ghi TCC.db được).
set -uo pipefail
bid=$1; now=$(date +%s)
for db in "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "/Library/Application Support/com.apple.TCC/TCC.db"; do
  s=""; [[ $db == /Library* ]] && s=sudo
  for svc in kTCCServiceSpeechRecognition kTCCServiceMicrophone; do
    $s sqlite3 "$db" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags,last_modified) VALUES ('$svc','$bid',0,2,3,1,'UNUSED',0,$now);" \
      && echo "FACTORY tcc ok $svc $( [[ -n $s ]] && echo sys || echo user)" || echo "FACTORY tcc fail $svc"
  done
done
