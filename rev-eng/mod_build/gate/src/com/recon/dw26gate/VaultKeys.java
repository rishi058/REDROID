package com.recon.dw26gate;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/**
 * Live 26.2 response-decryption key capture.
 *
 * 26.2 has no React-Native {@code getSecret} vault. Its encrypted response
 * fields (the {@code np_lelo} {@code fileInfo} blob and the {@code url} nested
 * inside it) are opened by {@code C5.c.a(String ciphertext, String password)},
 * a CryptoJS/OpenSSL AES-256-CBC decryptor; {@code C5.c.b(plaintext, password)}
 * is its request-side encrypt twin. The {@code password} argument is the live
 * content key either way, and for decrypt the return value is the plaintext, so
 * observing those calls recovers every key needed to decrypt a captured response
 * offline. PairIP moves the key-producing code into the {@code pairipcore}
 * native VM, so this runtime capture is the only reliable way to see the key.
 *
 * Unlike {@link ResponseBodies}, this deliberately retains the raw key and
 * plaintext -- recovering the content keys is the whole purpose. The output is
 * the app's private cache dir and is local-only research material: keep it out
 * of git and delete it when the analysis is done.
 */
final class VaultKeys {
    private static final long MAX_FILE_BYTES = 1024 * 1024;
    private static final int MAX_VALUE = 8192;
    private final File output;
    private int count;

    VaultKeys(String dataDir) {
        output = new File(new File(dataDir, "cache"), "dw26gate-keys.jsonl");
    }

    synchronized void record(String op, String key, String input, String result, boolean failed) {
        if (++count > 200) return;
        try {
            boolean decrypt = "decrypt".equals(op);
            String ciphertext = decrypt ? input : result;
            String plaintext = decrypt ? result : input;
            JSONObject record = new JSONObject();
            record.put("time_ms", System.currentTimeMillis());
            record.put("op", op);
            record.put("key", clip(key));
            record.put("key_len", key == null ? 0 : key.length());
            record.put("ciphertext", clip(ciphertext));
            record.put("plaintext", failed || plaintext == null ? JSONObject.NULL : clip(plaintext));
            record.put("role", role(plaintext, failed));
            record.put("failed", failed);
            byte[] line = (record.toString() + "\n").getBytes(StandardCharsets.UTF_8);
            File parent = output.getParentFile();
            if ((parent.isDirectory() || parent.mkdirs()) && output.length() + line.length <= MAX_FILE_BYTES) {
                try (FileOutputStream stream = new FileOutputStream(output, true)) {
                    stream.write(line);
                }
            }
        } catch (Exception ignored) {
            // Capture must never disturb the app's own decryption path.
        }
    }

    /** Label a captured plaintext so outer fileInfo vs inner url keys are obvious in the log. */
    static String role(String plaintext, boolean failed) {
        if (failed || plaintext == null) return "unknown";
        String text = plaintext.trim();
        if (text.startsWith("http://") || text.startsWith("https://")) return "inner-url";
        if (text.startsWith("{") && (text.contains("\"url\"") || text.contains("timeStamp"))) return "outer-fileInfo";
        if (text.startsWith("{") || text.startsWith("[")) return "json";
        return "text";
    }

    private static String clip(String value) {
        if (value == null) return null;
        return value.length() > MAX_VALUE ? value.substring(0, MAX_VALUE) + "<clip>" : value;
    }
}
