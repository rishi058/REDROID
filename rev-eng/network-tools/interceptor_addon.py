"""mitmdump addon: no-Frida enrollment interceptor (+ optional re-auth forcing).

Loads ProvisioningInterceptor from the environment (VIRTUAL_PROVISION_JOB_PATH
or VIRTUAL_PROVISION_JOB_DIR, RESIDENTIAL_GATEWAY_BASE_URL,
VIRTUAL_PRINCIPAL_MASTER_KEY). Only acts on the app's attest/challenge +
attest/verify; all other traffic passes through.

When FORCE_REAUTH=1, authenticated endpoints are answered with 401 UNTIL the app
starts attesting, pushing a warm, already-enrolled app into a full
attest/challenge + attest/verify (the flow the interceptor substitutes). The
latch is re-armed after each attest/verify so a QUEUE of identities is driven
one after another (each 401 -> attest -> substitute -> persist -> 503 -> re-arm).
"""
import os
import re
import sys
from urllib.parse import urlsplit

_SVC = os.environ.get("INTERCEPTOR_SVC_DIR", "/home/Rishi/delegated-tools/svc")
sys.path.insert(0, _SVC)
from services.virtual_principals.provisioning import ProvisioningInterceptor

_P = ProvisioningInterceptor.from_environment()
_FORCE_REAUTH = os.environ.get("FORCE_REAUTH", "0").lower() in ("1", "true", "yes")
_AUTHED = re.compile(
    r"/api/v2/android/(np_lelo|pp_lelo|np_dedo|pp_dedo|premium|playlist_items)$"
    r"|/api/v2/android/token/refresh$"
)
_state = {"attesting": False}

if _P is None:
    print("[interceptor] DISABLED (VIRTUAL_PROVISION_JOB_PATH unset)", file=sys.stderr)
else:
    print("[interceptor] ENABLED mode=%s device_id=%s alias=%s force_reauth=%s"
          % (_P.job.get("mode"), _P.job.get("device_id"), _P.job.get("alias"), _FORCE_REAUTH),
          file=sys.stderr)


def request(flow):  # noqa: ANN001
    if _P is None:
        return
    path = urlsplit(flow.request.pretty_url).path
    if "/attest/" in path:
        _state["attesting"] = True  # app is re-attesting; stop forcing 401s
    elif _FORCE_REAUTH and not _state["attesting"] and _AUTHED.search(path):
        from mitmproxy import http
        print("[interceptor] force-401 %s" % path, file=sys.stderr)
        flow.response = http.Response.make(
            401, b'{"message":"unauthorized","statusCode":401}',
            {"content-type": "application/json"},
        )
        return
    try:
        _P.handle(flow)
    except Exception as exc:  # noqa: BLE001
        try:
            _P._status(f"error_{type(exc).__name__}_{str(exc)[:160]}")
        except Exception:
            pass
        raise
    # Re-arm force-401 after each verify so the NEXT queued identity is driven.
    if path.endswith("/attest/verify"):
        _state["attesting"] = False
