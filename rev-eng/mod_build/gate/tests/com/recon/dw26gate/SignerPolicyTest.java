package com.recon.dw26gate;

import java.nio.charset.StandardCharsets;

public final class SignerPolicyTest {
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Signer policy invariant failed");
    }

    public static void main(String[] args) throws Exception {
        String body = "{\"id\":\"6a3fe4bc69eabf8720060b48\",\"t\":\"2026-09-27T10:01:10.273Z\",\"c_i\":{},\"user\":{},\"s\":false,\"dID\":\"296300d93fffe0c5\"}";
        String expectedHash = "6e1f7ff57175e7e9fbe9b1ea7b8b7811d7cc29dabc109edeb7760a49ace63309";
        check(expectedHash.equals(SignerPolicy.bodyHash(body.getBytes(StandardCharsets.UTF_8))));
        check(SignerPolicy.allowedPath("/api/v2/android/np_lelo"));
        check(SignerPolicy.allowedPath("/api/v2/android/premium"));
        check(SignerPolicy.allowedPath("/api/v2/android/playlist_items"));
        check(!SignerPolicy.allowedPath("/api/v2/android/token/refresh"));
        check(!SignerPolicy.allowedPath("https://api.diskwala.com/api/v2/android/np_lelo"));
        String canonical = new String(SignerPolicy.canonical(
            "/api/v2/android/np_lelo",
            1790503270274L,
            "TrHjJJDNOA-Oynw5cn7czg",
            body.getBytes(StandardCharsets.UTF_8)), StandardCharsets.UTF_8);
        String expected = "DW1\nPOST\n/api/v2/android/np_lelo\n1790503270274\n"
            + "TrHjJJDNOA-Oynw5cn7czg\n" + expectedHash;
        check(expected.equals(canonical));
        check(canonical.charAt(canonical.length() - 1) != '\n');
        System.out.println("SignerPolicyTest: 8 cases passed");
    }
}
