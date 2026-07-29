# What rev-eng is all about

This folder records a reverse-engineering attempt for a **Target App** in a
controlled ReDroid environment. It covers the setup, the two runtime
protection challenges, and the later work that turned captured encrypted
responses into readable local research output.

```text
ReDroid 13 + Magisk
    -> install Target App
    -> address PairIP and Talsec/freeRASP runtime blocks
    -> capture the genuine app request/response flow
    -> use static analysis and local diagnostic output to decrypt responses
```

## Tools used

- ReDroid 13
- Magisk with LSPosed
- ADB and logcat
- JADX for the Android/Java layer
- `hermes-dec` for the React Native Hermes bundle
- mitmproxy for local HTTPS capture
- Python for capture parsing and response decryption

## Step 1 — Set up ReDroid 13

Create a rooted ReDroid 13 instance and configure Magisk, a single Zygisk
provider, and LSPosed. Keep ADB private, verify that the Android system has
booted, and confirm that LSPosed can load a module only in the intended target
package.

The parent repository contains the ReDroid and Magisk setup material. This
folder assumes that the device is already available for authorized testing.

## Step 2 — Install the Target App

Install the original Target App APK without repackaging or re-signing it. This
preserves the app's expected signature and lets the genuine process perform
its own protected request flow.

The `apk-extractor/target-apk/` directory is a local staging area for the APK;
do not commit an APK, account data, raw captures, or other sensitive research
material unless it has been explicitly reviewed and redacted.

## Step 3 — First challenge: PairIP

The first launch block was PairIP, which performed local integrity and licence
checks before the app could reach its normal entry point. The issue was fixed
by using a scoped PairIPFix LSPosed module that neutralised the identified
local check/exit path without modifying the Target App APK.

The resulting module is an installable research dependency under
[`modules/`](modules/); it is separate from the custom module source in
[`mod_build/`](mod_build/).

## Step 4 — Second challenge: Talsec / freeRASP

Talsec/freeRASP then detected the instrumented environment and initiated a
threat reaction, including a delayed native self-termination path. The issue
was fixed with a narrowly scoped local LSPosed module that suppresses only the
proven reaction path, including the Java-to-JNI self-kill boundary.

The module's source, build recipe, and scope helper live in
[`mod_build/`](mod_build/). The research notes in
[`docs/04-native-selfkill-research.md`](docs/04-native-selfkill-research.md)
explain why the hook is kept narrow rather than broadly disabling unrelated
crypto or integrity methods.

## Step 5 — Network logs, key discovery, and response decryption

Once the Target App remained running, the main work was manual correlation
between static analysis, diagnostic logging, and HTTPS captures:

```text
APK / Hermes bundle + Java bridge
        -> identify vault key names and response format
        -> observe values through a narrowly scoped LSPosed module
        -> capture the genuine app request and encrypted response
        -> decrypt the response locally with the observed keys
```

### Analysis areas

| Area | Location | Purpose |
| --- | --- | --- |
| APK / bundle extraction | [`apk-extractor/`](apk-extractor/) | Unpack APK/APKS/XAPK files, find the React Native bundle, and scan for endpoints. |
| Java decompilation cache | [`apk-extractor/jadx-java-src/`](apk-extractor/jadx-java-src/) | Workspace for JADX output; follow the Android bridge into React Native. |
| Hermes output cache | [`apk-extractor/hermes-dec-output/`](apk-extractor/hermes-dec-output/) | Workspace for decompiled Hermes JavaScript and manual response-flow tracing. |
| Runtime instrumentation | [`mod_build/`](mod_build/) | Source and build recipe for the Target App-scoped LSPosed diagnostic module. |
| Network capture and parsing | [`network-tools/`](network-tools/) | Certificate setup, deep-link capture, flow export, and local decryption helpers. |
| Research notes | [`docs/`](docs/) | Starting point, dead ends, and the confirmed native self-kill path. |

Generated decompilation output and captures are deliberately kept out of the
source tree unless they have been reviewed and redacted.

### Manual key-discovery workflow

This finding came from manual digging rather than a single automatic tool:

1. Extract the Target App and retain the JADX Java output and Hermes-decompiled
   bundle for review.
2. In `jadx-java-src`, locate the React Native security/vault module and note
   bridge methods that accept a key or nonce and resolve a `Promise`.
3. In the Hermes output, search for those bridge method names and follow their
   callers into the endpoint response handler.
4. Record the *names* of the required vault values and the key-concatenation
   formula. The observed nested response needed `API_PLAY_INFO` and
   `API_URL_INFO`; the latter was combined with the response timestamp and an
   application suffix.
5. Confirm the encryption format from the bundle before implementing a local
   decryptor. The observed payloads were CryptoJS/OpenSSL-compatible
   `Salted__` blobs using AES-256-CBC and PKCS#7 padding.

Static analysis explains which values are needed; the Target App process
supplies its own live values; the local script only decodes a capture already
obtained from that process.

### Printing values through `mod_build`

[`mod_build/src/com/recon/talsecbypass/Hook.java`](mod_build/src/com/recon/talsecbypass/Hook.java)
wraps the React Native `Promise` used by `getSecret` and `getCryptogram`.
When the real bridge resolves a value, the wrapper records the key name and
resolved value in the LSPosed log, then forwards the original call so normal
app behaviour continues.

This is diagnostic instrumentation, not a replacement implementation of the
vault. The module stays scoped to the Target App and its self-kill fix leaves
unrelated native crypto/integrity methods untouched.

> **Sensitive output:** vault values, cryptograms, authorization headers,
> response bodies, and decrypted URLs can be credentials or private content.
> Keep logcat and capture files local, redact them before sharing, and remove
> diagnostic logging when it is no longer needed.

### Capture and local decryption

[`network-tools/deeplink_capture.py`](network-tools/deeplink_capture.py)
starts a local mitmproxy capture, triggers an Android deep link, and lets the
genuine Target App make its own authenticated request. It does not generate or
replay protected request values.

The decryptors consume an exported JSON flow plus values already observed from
the local Target App process:

- [`network-tools/decrypt.py`](network-tools/decrypt.py) decrypts a single
  capture after its local secret placeholders are supplied.
- [`network-tools/decrypt_all.py`](network-tools/decrypt_all.py) harvests
  locally saved diagnostic log lines and decrypts matching JSON captures in
  batch.

The response flow is:

```text
response.fileInfo
  -- decrypt with API_PLAY_INFO --> JSON containing timeStamp + encrypted URL
  -- decrypt URL with API_URL_INFO + timeStamp + app suffix --> readable URL
```

If decryption fails, verify the captured response type, the `Salted__` prefix,
the current vault values, timestamp, and suffix formula. A value returned
under an integrity/tamper condition may be a decoy rather than the content key.

## Minimal local setup

Install the Python dependencies and optional static-analysis tools:

```powershell
python -m pip install -r rev-eng/requirements.txt
python -m pip install hermes-dec rich
# Install JADX separately and make `jadx` available on PATH for Java output.
```

For an authorized APK, a typical static pass from the repository root is:

```powershell
python rev-eng/apk-extractor/apk_extractor.py `
  --apk rev-eng/apk-extractor/target-apk/app.apk `
  --base api.target.example `
  --java-dir rev-eng/apk-extractor/jadx-java-src `
  --keep-bundle
```

Use these tools only on devices, accounts, and applications you are authorized
to test. Do not publish raw captures, resolved vault values, or decrypted
private content.

## Current result

- The required key names and nested-response key formula were recovered by
  manually reading the JADX Java sources alongside Hermes-decompiled output.
- The local LSPosed module exposed values at the Target App's own promise
  boundary without modifying the APK.
- Captured encrypted responses could then be decrypted locally and correlated
  back to the relevant endpoint and response handler.
