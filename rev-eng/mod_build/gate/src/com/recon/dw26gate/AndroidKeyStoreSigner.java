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
import org.json.JSONObject;

/** Uses the existing DiskWala key in-place. It never creates, replaces, imports, or exports keys. */
final class AndroidKeyStoreSigner {
    private final SecureRandom random = new SecureRandom();

    boolean aliasPresent() {
        try {
            KeyStore store = loadStore();
            return store.containsAlias(SignerPolicy.KEY_ALIAS)
                && store.getCertificate(SignerPolicy.KEY_ALIAS) != null;
        } catch (Exception ignored) {
            return false;
        }
    }

    JSONObject sign(String path, byte[] body) throws Exception {
        KeyStore store = loadStore();
        Key key = store.getKey(SignerPolicy.KEY_ALIAS, null);
        Certificate certificate = store.getCertificate(SignerPolicy.KEY_ALIAS);
        if (!(key instanceof PrivateKey) || !"EC".equalsIgnoreCase(key.getAlgorithm())) {
            throw new IllegalStateException("private_key_unavailable");
        }
        if (certificate == null || !(certificate.getPublicKey() instanceof ECPublicKey)) {
            throw new IllegalStateException("public_key_unavailable");
        }
        ECPublicKey publicKey = (ECPublicKey) certificate.getPublicKey();
        if (publicKey.getParams() == null || publicKey.getParams().getCurve().getField().getFieldSize() != 256) {
            throw new IllegalStateException("unexpected_curve");
        }

        byte[] nonceBytes = new byte[16];
        random.nextBytes(nonceBytes);
        String nonce = Base64.getUrlEncoder().withoutPadding().encodeToString(nonceBytes);
        long timestamp = System.currentTimeMillis();
        byte[] canonical = SignerPolicy.canonical(path, timestamp, nonce, body);

        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign((PrivateKey) key);
        signer.update(canonical);
        byte[] signature = signer.sign();

        byte[] keyDigest = MessageDigest.getInstance("SHA-256")
            .digest(publicKey.getEncoded());
        String kid = Base64.getUrlEncoder().withoutPadding().encodeToString(keyDigest);

        JSONObject result = new JSONObject();
        result.put("kid", kid);
        result.put("ts", Long.toString(timestamp));
        result.put("nonce", nonce);
        result.put("sig", Base64.getEncoder().encodeToString(signature));
        result.put("body_sha256", SignerPolicy.bodyHash(body));
        return result;
    }

    private static KeyStore loadStore() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        return store;
    }
}
