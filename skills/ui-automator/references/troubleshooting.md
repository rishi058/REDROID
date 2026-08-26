# Troubleshooting / Gotchas

Collected from live sessions on Windows (PowerShell 7) + redroid over SSH tunnel.

## Connectivity

| Symptom | Cause | Fix |
|---|---|---|
| `cannot connect ... refused (10061)` | SSH tunnel dead | Restart tunnel background job, then `adb connect` |
| `device offline` | adbd restarted (container restart) or tunnel flapped | `adb disconnect S; adb kill-server; adb start-server; adb connect S; adb devices` |
| `adb: error: failed to get feature set: device offline` during pull | Device dropped mid-transfer | Reconnect, redo dump+pull |
| Two devices listed (`5557`, `emulator-5556`) | Local WSL instance also attached | Always use `-s SERIAL` |

## Dump problems

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: could not get idle state` | Animations/progress spinners keep UI busy | Wait 1-2 s and retry; press BACK to dismiss spinner screens |
| Dump shows previous screen | Screen changed after dump started | Sleep after actions BEFORE dumping; re-dump |
| Sheet/dialog missing from dump | It never opened (tap hit wrong spot) | Verify `mCurrentFocus`; re-tap using computed center |
| Item absent but should exist | Below the fold in a virtualized list | Swipe up, re-dump |

## Input problems

| Symptom | Cause | Fix |
|---|---|---|
| Tap does nothing | Tapped text child of non-clickable row at screen edge; sheet dismissed instead | Tap row center across full width (x = screen_width/2); verify with re-dump |
| Tap opens wrong thing | Stale coordinates from an earlier layout | NEVER reuse coordinates from old dumps — always fresh dump → find → tap |
| `input text` fails on spaces | Shell quoting | Use `%s` for space: `input text hello%sworld` |
| BACK dismissed a dialog you wanted | Focus was on dialog layer | Check focus before keyevents |

## Host-side (Windows PowerShell) pitfalls

1. **No `<` redirection** — PowerShell reserves it. Pipe instead:
   `Get-Content -Raw script.sh | ssh host "tr -d '\r' | bash -s"`
2. **CRLF kills bash** — files written on Windows must be stripped before remote bash:
   pipe through `tr -d '\r'` (or write scripts with LF endings).
3. **`&` chains create background jobs** in PowerShell, not shell sequencing —
   separate commands with `;`.
4. **`$var:` inside double quotes** — PowerShell parses `$C:/path` as a scoped
   variable and errors (`Variable reference is not valid`). Avoid `$x:` patterns;
   use script-pipe style for anything complex.
5. **Inline python one-liners with nested quotes** break easily — prefer writing a
   small `.py` file (see scripts/) and running `python file.py args`.
6. **Long-running command output lost** — shell-integration may not flush output of
   sleeping pipelines. Prefer short foreground calls; read artifacts from disk.

## App-specific notes

- **Play Store**: resource-ids are obfuscated (`0_resource_name_obfuscated`); match by
  text/desc/bounds only.
- **Play Integrity checker**: verdict JSON body is invisible to uiautomator AND
  clipboard reads are blocked on A14 — use the Pass/Fail content-desc icons.
- **WebView URLs hijack**: VIEW intents to play.google.com open the webview shell,
  not Play Store — navigate via UI taps instead.
