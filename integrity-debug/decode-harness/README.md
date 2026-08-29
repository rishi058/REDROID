# Phase D.1 — Decode-once harness (GCP setup)

The decisive test. Separates **token replay/stale clearing** from a **genuine device fail**.
The public checker (`gr.nikolasspyr.integritycheck`) decodes through its own server, so its
"all UNEVALUATED" result is ambiguous. Decoding a **fresh** token **once** with our own
service account removes the ambiguity.

## One-time Google Cloud setup (free tier)

1. Create a Google Cloud project → note the **project number** (not the ID).
2. Enable the **Play Integrity API** for that project.
3. Create a **service account** → add key → download JSON → save as `service-account.json` here.
4. Grant the service account access to decode (it can decode tokens minted for apps linked to
   this project; for a standalone debug app you use the project number directly — no Play Console
   publication required for `deviceIntegrity`).

## Use

1. Build/install `../probe-app` (set `CLOUD_PROJECT_NUMBER` to your project number).
2. On exp (5557), open the probe app → it warms up the provider and mints a **fresh** token,
   printed to logcat (tag `PROBE`) and on-screen.
3. Immediately decode it once:

```bash
python decode_token.py --package <probe.app.id> --token "<TOKEN>" --sa service-account.json
```

## Reading the result

| deviceRecognitionVerdict | appRecognitionVerdict | Meaning |
|---|---|---|
| contains `MEETS_*` | any | Device **genuinely passes** — the checker was misleading |
| empty/absent | not `UNEVALUATED` | **Genuine fail** — device not trusted (pursue env-signal / keybox) |
| empty/absent | `UNEVALUATED` (all fields) | **Replay/stale** — re-run with a brand-new token |

> Tokens are single-use. Never decode the same token twice or you manufacture the ambiguous case.

## No-GCP fallback

If you can't create a GCP project, install a **Classic-request** checker (mints + decodes
differently) as a second opinion, but it still uses a third-party server — less precise than this.
