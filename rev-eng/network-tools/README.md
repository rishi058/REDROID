# HTTPS interception + traffic analysis (monitor the app's endpoints)


**Files:**
- `install_cert.sh` — install the mitmproxy CA into the device **system** trust store.
  On Android 14 it installs into the active Conscrypt APEX path
  (`/apex/com.android.conscrypt/cacerts/<hash>.0`) as well as the legacy
  `/system/etc/security/cacerts/<hash>.0`; React Native trusts only system CAs.
  The CA + its Android-hashed filename are in [certs/](certs/). The file must
  be named with the old-style subject hash (for example `c8750f0d.0`), not an
  arbitrary name.

- `parse_flows.py <flows.mitm>` — summarise hosts + endpoints captured.

**Certificate file (CA) notes:**
- To extract a CA that is already installed on the device, find it in the system trust store and pull it out:
  ```bash
  adb shell ls /system/etc/security/cacerts | grep -i 'c8750f0d'
  adb pull /system/etc/security/cacerts/c8750f0d.0 ./certs/c8750f0d.0
  ```
- To create a new CA from mitmproxy, run mitmproxy/mitmdump once first so it generates the CA at
  `~/.mitmproxy/mitmproxy-ca-cert.pem`, then convert it and give it the Android-style hashed filename:
  ```bash
  openssl x509 -in ~/.mitmproxy/mitmproxy-ca-cert.pem -outform DER -out /tmp/mitmproxy.cer
  openssl x509 -inform PEM -in ~/.mitmproxy/mitmproxy-ca-cert.pem -noout -subject_hash_old
  ```
  The second command prints the hash you should use as the filename, for example
  `/<hash>.0` under `/system/etc/security/cacerts/`.
- If you want a local PEM copy as well, keep one beside the Android `.0` file:
  ```bash
  cp ~/.mitmproxy/mitmproxy-ca-cert.pem ./certs/mitmproxy-ca-cert.pem
  ```
- One-shot install example for a newly generated CA:
  ```bash
  HASH=$(openssl x509 -inform PEM -in ~/.mitmproxy/mitmproxy-ca-cert.pem -noout -subject_hash_old)
  cp ~/.mitmproxy/mitmproxy-ca-cert.pem ./certs/${HASH}.0
  adb push ./certs/${HASH}.0 /data/local/tmp/${HASH}.0
  adb shell "su 0 sh /data/local/tmp/install_cert.sh"
  ```

- `dump_flows.py <flows.mitm> <host-filter>` — dump full req/resp (headers+bodies) → JSON.

- **`capture-live-networks.py`** — live browser-network-style capture. It starts
  `mitmdump`, runs the working `adb reverse` + Android global-proxy setup, and
  writes every observed request/response (headers, bodies, timings, connection
  details, errors and WebSocket messages) to a uniquely timestamped JSON file in
  `captures/`. The JSON is updated after each flow, so it remains usable if the
  capture is interrupted. Application-level ciphertext is preserved as captured;
  this tool does not attempt to decrypt it.

  ```bash
  cd rev-eng/network-tools
  python capture-live-networks.py
  # output: captures/network_YYYYMMDD_HHMMSS_microseconds.json
  # Ctrl+C stops mitmdump and restores the prior Android HTTP proxy setting.
  ```

  The system mitmproxy CA must already be installed first. For a specific ADB
  target, use `--serial <serial>`; use `--leave-proxy` only when you deliberately
  want the device to keep routing through the proxy after this script stops.

- **`captures/deeplink_capture.py`** — a generic Android intent capture tool. Supply the target
  package and URI yourself; it starts mitmdump, temporarily sets the selected device's proxy,
  launches the intent, and exports matching traffic. Optional `--method`, `--request-body` or
  `--request-body-file`, `--host`, and `--path-contains` arguments are capture filters. They do
  not forge a request: the selected app still chooses its own HTTP method, body, and credentials.

  ```bash
  python captures/deeplink_capture.py --pkg com.example.app --uri myapp://open/42
  python captures/deeplink_capture.py --pkg com.example.app --uri myapp://open/42 \
    --method POST --request-body-file body.json --host api.example.test
  ```

  Use `--extra KEY=VALUE` repeatedly for app-specific string intent extras, `--serial` to select
  an ADB device, and `--leave-proxy` only when deliberately preserving the capture proxy. By
  default the script restores the previous Android proxy setting when it finishes.

**Typical run:**
```bash
mitmdump -p 8080 --set block_global=false -w data/captures/flows.mitm      # host proxy
adb shell "/system/xbin/su 0 sh /data/local/tmp/install_cert.sh"            # (push install_cert.sh first)
adb reverse tcp:8080 tcp:8080 ; adb shell settings put global http_proxy 127.0.0.1:8080  # set reverse proxy

adb shell am start -a android.intent.action.VIEW -d "https://www.target-app.com/app/<id>" com.target-appapp

python tools/capture/dump_flows.py data/captures/flows.mitm target-app        # -> traffic_target-app.json
```
