#!/usr/bin/env bash
# Runs Pagewise's built-in self-test (debug builds only) and prints the
# results. It indexes a sample PDF it makes itself, then asks it questions
# with known answers.
set -euo pipefail
LOG="$HOME/Library/Logs/Pagewise/pagewise.log"
start=$(wc -l < "$LOG" 2>/dev/null || echo 0)
/usr/bin/swift - <<'SWIFT'
import Foundation
DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("com.barrynapier.pagewise.selftest"), object: nil, userInfo: nil, deliverImmediately: true)
SWIFT
for _ in $(seq 1 400); do
  sleep 1
  if tail -n +"$((start + 1))" "$LOG" | grep -qE "SELFTEST (PASS|FAIL [0-9]+ check)"; then break; fi
done
tail -n +"$((start + 1))" "$LOG" | grep -E "SELFTEST" | cut -c15-
