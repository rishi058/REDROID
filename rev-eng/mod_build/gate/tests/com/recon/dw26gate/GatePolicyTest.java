package com.recon.dw26gate;

public final class GatePolicyTest {
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Gate policy invariant failed");
    }

    public static void main(String[] args) {
        check("com.diskwalaapp".equals(GatePolicy.PACKAGE));
        check("device_not_trusted".equals(GatePolicy.code("device_not_trusted")));
        check("<redacted>".equals(GatePolicy.code("token-or-personal-data")));
        check("<redacted>".equals(GatePolicy.code(200)));
        check("none".equals(GatePolicy.code(null)));
        check("login".equals(GatePolicy.endpoint("login")));
        check("<other>".equals(GatePolicy.endpoint("login?token=secret")));
        check(!GatePolicy.showSignedOut(GateMode.OBSERVE, "UNSUPPORTED", true));
        check(!GatePolicy.showSignedOut(GateMode.LOCAL, "UNSUPPORTED", false));
        check(!GatePolicy.showSignedOut(GateMode.LOCAL, "CHECKING", true));
        check(GatePolicy.showSignedOut(GateMode.LOCAL, "UNSUPPORTED", true));
        check(!GatePolicy.mockAllowed(GateMode.OBSERVE, "attest/verify"));
        check(!GatePolicy.mockAllowed(GateMode.MOCK, "login"));
        check(!GatePolicy.mockAllowed(GateMode.MOCK, "attest/challenge"));
        check(!GatePolicy.mockAllowed(GateMode.MOCK, "https://api.diskwala.com/attest/verify"));
        check(GatePolicy.mockAllowed(GateMode.MOCK, "attest/verify"));
        check(GatePolicy.mockAllowed(GateMode.MOCK, "appuser/version"));
        check(!GatePolicy.legacyDiagnosticsEnabled(GateMode.OBSERVE));
        check(!GatePolicy.legacyDiagnosticsEnabled(GateMode.OFF));
        check(GatePolicy.legacyDiagnosticsEnabled(GateMode.LOCAL));
        check(GatePolicy.legacyDiagnosticsEnabled(GateMode.MOCK));
        check(!GatePolicy.legacyDiagnosticsEnabled(GateMode.SIGNER));
        check(GatePolicy.signerEnabled(GateMode.SIGNER));
        check(!GatePolicy.signerEnabled(GateMode.OBSERVE));
        System.out.println("GatePolicyTest: 24 cases passed");
    }
}
