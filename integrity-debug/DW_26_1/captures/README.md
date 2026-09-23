# DiskWala URL traffic captures

`dw26_link_6a29a4a769eabf87208aa8cd.json` is a sanitized capture for the URL supplied during this run.

`dw26_link_6a29a4a769eabf87208aa8cd_full.json` is the requested complete,
unredacted DiskWala-only capture. It retains all headers and request/response bodies
for `api.diskwala.com` and `tn1.diskwala.com`, including session/device-related data.
It must remain local, must not be committed/shared, and should be deleted after the
required reverse-engineering work is complete.

Capture conditions:

- DiskWala was already authenticated and running locally in ReDroid.
- The public local mitmproxy CA was trusted by Android's system and Conscrypt stores.
- ADB reverse forwarded Android port `18887` to the host mitmproxy listener.
- The global proxy was restored to `:0` and the reverse mapping was removed immediately after capture.

Only `api.diskwala.com` and `tn1.diskwala.com` records were retained. Raw global proxy traffic was written only under the approved temporary directory, then deleted. The sanitized JSON:

- removes authorization/cookie headers;
- redacts device IDs, tokens, key IDs, challenges, certificate chains, assertions, e-mail addresses, JWTs and opaque values;
- strips query strings from saved paths;
- retains method, host, path, status, body sizes, safe headers and redacted JSON.

The captured endpoint for the pasted URL was:

```text
POST https://api.diskwala.com/api/v2/android/np_lelo
HTTP 200
```

The request ID is the link identifier from the URL. The response includes uploader metadata and an opaque `fileInfo` value, which remains redacted because it is application-level protected data.
