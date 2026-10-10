package com.recon.dw26gate;

import java.security.Key;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.cert.Certificate;
import java.security.interfaces.ECPublicKey;
import java.util.Base64;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Uses the enrolled DiskWala attestation key(s) in-place. It never creates,
 * replaces, imports, or exports keys.
 *
 * One daemon can serve many device identities: every enrolled key is an
 * AndroidKeyStore alias under the app uid ({@link SignerPolicy#ALIAS_PREFIX}).
 * A request selects one by {@code kid} (urlsafe-b64 SHA-256 of the SPKI); with no
 * kid the default {@link SignerPolicy#KEY_ALIAS} is used (backward compatible).
 */
final class AndroidKeyStoreSigner {
    private final SecureRandom random = new SecureRandom();

    /** True if at least one selectable EC attestation alias is present. */
    boolean aliasPresent() {
        try {
            return !kidToAlias().isEmpty()
                || loadStore().getCertificate(SignerPolicy.KEY_ALIAS) != null;
        } catch (Exception ignored) {
            return false;
        }
    }

    /** All selectable aliases as [{alias, kid}, ...] for registry reconciliation. */
    JSONArray aliases() throws Exception {
        JSONArray out = new JSONArray();
        for (Map.Entry<String, String> e : kidToAlias().entrySet()) {
            out.put(new JSONObject().put("kid", e.getKey()).put("alias", e.getValue()));
        }
        return out;
    }

    /** Sign the DW1 request proof with the key selected by {@code kid} (nullable). */
    JSONObject sign(String path, byte[] body, String kid) throws Exception {
        KeyStore store = loadStore();
        String alias = resolveAlias(store, kid);
        ECKeyParts parts = ecParts(store, alias);

        byte[] nonceBytes = new byte[16];
        random.nextBytes(nonceBytes);
        String nonce = Base64.getUrlEncoder().withoutPadding().encodeToString(nonceBytes);
        long timestamp = System.currentTimeMillis();
        byte[] canonical = SignerPolicy.canonical(path, timestamp, nonce, body);

        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign(parts.privateKey);
        signer.update(canonical);
        byte[] signature = signer.sign();

        JSONObject result = new JSONObject();
        result.put("kid", parts.kid);
        result.put("ts", Long.toString(timestamp));
        result.put("nonce", nonce);
        result.put("sig", Base64.getEncoder().encodeToString(signature));
        result.put("body_sha256", SignerPolicy.bodyHash(body));
        return result;
    }

    /**
     * Sign a token/refresh challenge assertion with the key selected by {@code kid}.
     *
     * The app signs ECDSA over sha256(sha256(challenge)). With a keystore key whose
     * authorized digest is SHA-256, this is produced by pre-hashing the challenge
     * once (inner = sha256(challenge)) and letting SHA256withECDSA hash it again,
     * so the signed digest is sha256(inner) = sha256(sha256(challenge)) — identical
     * to provision_full.sign_challenge / signer.refresh_challenge_assertion.
     */
    JSONObject refreshAssertion(byte[] challenge, String kid) throws Exception {
        if (!SignerPolicy.validChallenge(challenge)) {
            throw new IllegalArgumentException("challenge_invalid");
        }
        KeyStore store = loadStore();
        String alias = resolveAlias(store, kid);
        ECKeyParts parts = ecParts(store, alias);

        byte[] inner = MessageDigest.getInstance("SHA-256").digest(challenge);
        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign(parts.privateKey);
        signer.update(inner);
        byte[] signature = signer.sign();

        JSONObject result = new JSONObject();
        result.put("kid", parts.kid);
        result.put("assertion", Base64.getEncoder().encodeToString(signature));
        return result;
    }

    // ---- internals -----------------------------------------------------------

    private String resolveAlias(KeyStore store, String kid) throws Exception {
        if (kid == null || kid.isEmpty()) {
            return SignerPolicy.KEY_ALIAS;
        }
        if (!SignerPolicy.validKid(kid)) {
            throw new IllegalArgumentException("kid_invalid");
        }
        String alias = kidToAlias().get(kid);
        if (alias == null) {
            throw new IllegalStateException("kid_not_enrolled");
        }
        return alias;
    }

    /** Map kid -> alias across all selectable EC aliases under this uid. */
    private Map<String, String> kidToAlias() throws Exception {
        KeyStore store = loadStore();
        Map<String, String> map = new LinkedHashMap<>();
        for (Enumeration<String> e = store.aliases(); e.hasMoreElements(); ) {
            String alias = e.nextElement();
            if (!SignerPolicy.selectableAlias(alias)) continue;
            try {
                Certificate cert = store.getCertificate(alias);
                if (cert == null || !(cert.getPublicKey() instanceof ECPublicKey)) continue;
                map.put(kidOf((ECPublicKey) cert.getPublicKey()), alias);
            } catch (Exception skip) {
                // ignore an alias we cannot read; others may still serve.
            }
        }
        return map;
    }

    private ECKeyParts ecParts(KeyStore store, String alias) throws Exception {
        Key key = store.getKey(alias, null);
        Certificate certificate = store.getCertificate(alias);
        if (!(key instanceof PrivateKey) || !"EC".equalsIgnoreCase(key.getAlgorithm())) {
            throw new IllegalStateException("private_key_unavailable");
        }
        if (certificate == null || !(certificate.getPublicKey() instanceof ECPublicKey)) {
            throw new IllegalStateException("public_key_unavailable");
        }
        ECPublicKey publicKey = (ECPublicKey) certificate.getPublicKey();
        if (publicKey.getParams() == null
            || publicKey.getParams().getCurve().getField().getFieldSize() != 256) {
            throw new IllegalStateException("unexpected_curve");
        }
        return new ECKeyParts((PrivateKey) key, kidOf(publicKey));
    }

    private static String kidOf(ECPublicKey publicKey) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(publicKey.getEncoded());
        return Base64.getUrlEncoder().withoutPadding().encodeToString(digest);
    }

    private static KeyStore loadStore() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        return store;
    }

    private static final class ECKeyParts {
        final PrivateKey privateKey;
        final String kid;

        ECKeyParts(PrivateKey privateKey, String kid) {
            this.privateKey = privateKey;
            this.kid = kid;
        }
    }
}
