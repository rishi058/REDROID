package com.recon.dw26gate;

public final class GatePrivacyTest {
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Capture redaction invariant failed");
    }

    public static void main(String[] args) {
        check(GatePrivacy.sensitive("integrityToken"));
        check(GatePrivacy.sensitive("Authorization"));
        check(GatePrivacy.sensitive("ANDROID_ID"));
        check(GatePrivacy.sensitive("keyId"));
        check(GatePrivacy.sensitive("chain"));
        check(GatePrivacy.sensitive("device_id"));
        check(GatePrivacy.sensitive("nonce"));
        check(GatePrivacy.sensitive("access"));
        check(GatePrivacy.sensitive("refresh"));
        check(GatePrivacy.sensitive("REFRESH"));
        check(!GatePrivacy.sensitive("error"));
        check(!GatePrivacy.sensitive("reason"));
        check("attestation_failed".equals(GatePrivacy.text("attestation_failed")));
        check("<email>".equals(GatePrivacy.text("test@example.invalid")));
        check("<identifier>".equals(GatePrivacy.text("0123456789abcdef")));
        check(!GatePrivacy.text("X".repeat(200)).contains("X".repeat(48)));
        check("<opaque>".equals(GatePrivacy.text("Q".repeat(43))));
        check("<jwt>".equals(GatePrivacy.text("A".repeat(12) + "." + "B".repeat(12) + "." + "C".repeat(12))));
        check("device_belongs_to_another_account".equals(GatePrivacy.text("device_belongs_to_another_account")));
        System.out.println("GatePrivacyTest: 19 cases passed");
    }
}
