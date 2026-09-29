package com.recon.dw26gate;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/** Log allowlists: arbitrary server strings, tokens, and identifiers are excluded. */
final class GatePolicy {
    static final String PACKAGE = "com.diskwalaapp";
    private static final Set<String> CODES = new HashSet<>(Arrays.asList(
        "device_not_trusted", "attestation_failed", "attest_key_unknown",
        "refresh_invalid", "refresh_device_mismatch", "device_belongs_to_another_account",
        "unauthorized", "forbidden", "rate_limited", "no_play_account", "timeout",
        "hardware_attestation_required", "invalid_assertion", "challenge_expired"));
    private static final Set<String> PATHS = new HashSet<>(Arrays.asList(
        "login", "logout", "refresh", "bootstrap", "config", "session", "me",
        "attest/challenge", "attest/register", "attest/verify", "attest/key",
        "attest/complete", "attest", "device/register", "appuser/version", "token/refresh",
        "attest/renew"));

    static String code(Object value) {
        if (value == null) return "none";
        return value instanceof String && CODES.contains(value) ? (String) value : "<redacted>";
    }

    static String endpoint(Object value) {
        return value instanceof String && PATHS.contains(value) ? (String) value : "<other>";
    }

    static boolean showSignedOut(GateMode mode, String state, boolean hasModel) {
        return mode == GateMode.LOCAL && "UNSUPPORTED".equals(state) && hasModel;
    }

    static boolean mockAllowed(GateMode mode, String endpoint) {
        // No Google, challenge issuance, login, refresh, or credential endpoints.
        return mode == GateMode.MOCK && ("attest/verify".equals(endpoint)
            || "appuser/version".equals(endpoint));
    }

    static boolean legacyDiagnosticsEnabled(GateMode mode) {
        // These older obfuscated hooks include a sensitive content-key oracle.
        // Package-scoped OBSERVE must not enable them on arbitrary updated APKs.
        return mode == GateMode.LOCAL || mode == GateMode.MOCK;
    }

    static boolean signerEnabled(GateMode mode) {
        return mode == GateMode.SIGNER;
    }

    private GatePolicy() {}
}
