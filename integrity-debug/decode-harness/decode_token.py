#!/usr/bin/env python3
"""Phase D.1 - decode a Play Integrity token EXACTLY ONCE, server-side.

This is the DECISIVE probe. Google's Standard API clears verdicts to the exact
"all UNEVALUATED / empty device verdict" shape when a token is decoded more than
once (replay protection). The public checker apps use their own decode server, so
a single stale/reused decode is indistinguishable from a genuine device fail.
Decoding a FRESH token ONCE with our own service account removes that ambiguity.

Flow:
  1. On the device, a debug app (see ../probe-app) requests a FRESH integrity token
     using OUR Google Cloud project number, and prints/returns the token string.
  2. Feed that token here immediately (tokens are single-use):
       python decode_token.py --package <appId> --token <TOKEN> --sa service-account.json
  3. Read deviceIntegrity.deviceRecognitionVerdict:
       - contains MEETS_BASIC_INTEGRITY/MEETS_DEVICE_INTEGRITY  -> device genuinely passes
       - empty/absent BUT appIntegrity != UNEVALUATED           -> genuine device fail
       - EVERYTHING UNEVALUATED + device empty                  -> replay/stale (re-run with a FRESH token)

Requires: pip install google-auth requests   (service account with playintegrity scope)
"""
import argparse, json, sys
try:
    import requests
    from google.oauth2 import service_account
    from google.auth.transport.requests import Request
except ImportError:
    sys.exit("pip install google-auth requests")

SCOPE = "https://www.googleapis.com/auth/playintegrity"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True, help="app package name the token was minted for")
    ap.add_argument("--token", required=True, help="fresh integrity token (single use)")
    ap.add_argument("--sa", required=True, help="path to GCP service-account JSON")
    a = ap.parse_args()

    creds = service_account.Credentials.from_service_account_file(a.sa, scopes=[SCOPE])
    creds.refresh(Request())
    url = f"https://playintegrity.googleapis.com/v1/{a.package}:decodeIntegrityToken"
    r = requests.post(url, headers={"Authorization": f"Bearer {creds.token}"},
                      json={"integrity_token": a.token}, timeout=30)
    if r.status_code != 200:
        print(f"HTTP {r.status_code}: {r.text}", file=sys.stderr); sys.exit(1)

    payload = r.json().get("tokenPayloadExternal", r.json())
    print(json.dumps(payload, indent=2))

    dev = payload.get("deviceIntegrity", {})
    drv = dev.get("deviceRecognitionVerdict", [])
    app = payload.get("appIntegrity", {}).get("appRecognitionVerdict", "?")
    print("\n=== DIAGNOSIS ===", file=sys.stderr)
    if drv:
        print(f"GENUINE PASS: deviceRecognitionVerdict = {drv}", file=sys.stderr)
    elif app != "UNEVALUATED":
        print("GENUINE FAIL: device verdict empty but app WAS evaluated -> real device-not-trusted", file=sys.stderr)
    else:
        print("AMBIGUOUS/REPLAY: everything UNEVALUATED -> likely a reused/stale token. Re-run with a FRESH token.", file=sys.stderr)

if __name__ == "__main__":
    main()
