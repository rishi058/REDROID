# Proven Workflows (battle-tested in this repo)

Real sequences executed successfully against redroid-experimental (`127.0.0.1:5557`,
720x1280). Adapt coordinates/labels per device.

## W1. Generic "find and tap" loop

```text
1. screen_state.sh            # confirm the expected app/window has focus
2. ui_dump.sh                 # capture hierarchy
3. parse_ui.py dump.xml       # eyeball visible text/desc + bounds
4. find_node.py dump.xml "Label"   → get CENTER
5. adb input tap X Y
6. sleep, re-dump, verify the new screen state
```

Rules of thumb:
- After every tap: `Start-Sleep 2-5` (screens animate), then re-dump.
- If `NO_MATCH`: the item may be below the fold → swipe up, re-dump.
- Prefer matching `content-desc` for icons (`--desc`), `text` for labels.

## W2. Scrolling bottom sheet (Play Store account menu)

Observed layout (720x1280): avatar button at `[604,60][692,148]` → center (648,104).

```bash
adb shell input tap 648 104                       # open account sheet
adb shell uiautomator dump ... && adb pull ...    # dump
# rows are ~116px apart; if target row y > ~1224 it is cut off:
adb shell input swipe 360 1000 360 450 400        # scroll sheet content
# re-dump, then find_node.py dump.xml "Play Protect" and tap its center x=360
```

Lessons:
- Tapping the *text bounds* near the screen edge can dismiss the sheet instead of
  navigating — tap the row center across full width (x=360).
- Sheet scroll position varies between opens; always re-dump after each scroll.

## W3. Play Protect scan

```text
W2 to reach "Play Protect" row → tap
→ screen shows "Scanning in progress…" or "No harmful apps found / scanned Xm ago"
→ optional fresh scan: find_node.py "Scan" (Button [240,656][480,736]) → tap (360,696)
→ wait 40 s → re-dump → assert "No harmful apps found"
```

## W4. Play Integrity checker verdict capture

```bash
adb -s S shell am force-stop gr.nikolasspyr.integritycheck
adb -s S shell am start -W -n gr.nikolasspyr.integritycheck/.MainActivity   # Status: ok
# CHECK button lives at [272,829][448,925] → tap 360 877
adb -s S shell input tap 360 877
sleep 20                                            # token request takes 10–18 s
ui_dump.sh; check_verdict.py final.xml              # HAS_PASS/HAS_FAIL + counts
```

Raw JSON dialog: tap `content-desc="Show JSON response"` (bounds `[528,56][640,152]`
→ center 584,104). NOTE: the dialog's JSON body TextView is NOT exposed to
uiautomator (only title/COPY/OK buttons are visible in the dump); clipboard route
(`dumpsys clipboard`) also returns empty on Android 14. Capture verdicts from the
main screen icons or logcat (`Finsky: requestIntegrityToken() finished`) instead.

## W5. Launch-state verification

```bash
am start -W -n PKG/.MainActivity | grep -E "Status|LaunchState"
dumpsys window | grep mCurrentFocus     # window must be the target app before dumping
```

If `mCurrentFocus=null`, wait and retry; a transition animation is in flight.

## W6. Post-restart reconnect (redroid container)

```powershell
adb disconnect SERIAL; adb kill-server; adb start-server
adb connect 127.0.0.1:5557; adb devices      # expect 'device' after ~2 s
```

If connection refused → SSH tunnel died; restart the tunnel job first.
