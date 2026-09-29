package com.recon.dw26gate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/** Pure request-proof policy and canonicalization shared by the bridge and host tests. */
final class SignerPolicy {
    static final String KEY_ALIAS = "com.diskwalaapp.attest.ec.v1";
    static final int MAX_BODY_BYTES = 16 * 1024;
    static final int MAX_FRAME_BYTES = 24 * 1024;
    private static final Set<String> PATHS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
        "/api/v2/android/np_lelo",
        "/api/v2/android/pp_lelo",
        "/api/v2/android/np_dedo",
        "/api/v2/android/pp_dedo",
        "/api/v2/android/premium",
        "/api/v2/android/playlist_items"
    )));

    static boolean allowedPath(String path) {
        return path != null && PATHS.contains(path);
    }

    static String bodyHash(byte[] body) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(body);
        StringBuilder result = new StringBuilder(digest.length * 2);
        for (byte value : digest) result.append(String.format("%02x", value & 0xff));
        return result.toString();
    }

    static byte[] canonical(String path, long timestamp, String nonce, byte[] body) throws Exception {
        if (!allowedPath(path)) throw new IllegalArgumentException("path_not_allowed");
        if (body == null || body.length > MAX_BODY_BYTES) {
            throw new IllegalArgumentException("body_size_invalid");
        }
        if (timestamp <= 0 || nonce == null || nonce.isEmpty()) {
            throw new IllegalArgumentException("proof_fields_invalid");
        }
        String value = "DW1\nPOST\n" + path + "\n" + timestamp + "\n" + nonce + "\n" + bodyHash(body);
        return value.getBytes(StandardCharsets.UTF_8);
    }

    private SignerPolicy() {}
}
