source scripts/lib.sh
test_peak_paused() {
  peak_paused x 10 0.9 && r=nghi || r=chay; assert_eq nghi "$r" peak_over_85_in_hours
  peak_paused x 10 0.84 && r=nghi || r=chay; assert_eq chay "$r" peak_under_85
  peak_paused x 18 0.99 && r=nghi || r=chay; assert_eq chay "$r" peak_after_6pm
  peak_paused x 06 0.99 && r=nghi || r=chay; assert_eq chay "$r" peak_before_7am
  peak_paused x 07 0.85 && r=nghi || r=chay; assert_eq nghi "$r" peak_at_7am_exact_85
  peak_paused x 12 "" && r=nghi || r=chay; assert_eq chay "$r" peak_unknown_usage_runs
  now=$(date +%s)
  peak_paused x 22 0.1 0.9 $((now + 4*86400)) && r=nghi || r=chay; assert_eq nghi "$r" week_85_reset_4d_off_hours
  peak_paused x 22 0.1 0.9 $((now + 2*86400)) && r=nghi || r=chay; assert_eq chay "$r" week_85_reset_2d_runs
  peak_paused x 22 0.1 0.84 $((now + 5*86400)) && r=nghi || r=chay; assert_eq chay "$r" week_under_85_runs
  peak_paused x 22 0.1 "" "" && r=nghi || r=chay; assert_eq chay "$r" week_unknown_runs
}
