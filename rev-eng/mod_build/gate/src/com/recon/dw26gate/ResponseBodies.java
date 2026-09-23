package com.recon.dw26gate;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import org.json.JSONArray;
import org.json.JSONObject;

/** Capture only redacted JSON, never raw HTTP headers or request credentials. */
final class ResponseBodies {
    private static final long MAX_FILE_BYTES = 512 * 1024;
    private final File output;
    private int count;

    ResponseBodies(String dataDir) {
        output = new File(new File(dataDir, "cache"), "dw26gate-responses.jsonl");
    }

    synchronized String record(String endpoint, int status, Object body, boolean mocked) throws Exception {
        if (++count > 40) return "<capture-budget-reached>";
        // The E5.g body is already an in-memory JsonObject. This does not consume
        // an OkHttp response stream or change how the app can read the response.
        String json = body == null ? "null" : body.toString();
        Object safe;
        if (json.length() > 65536) {
            safe = "<oversized body omitted>";
        } else if (body == null) {
            safe = JSONObject.NULL;
        } else {
            JSONObject parsed = new JSONObject(json);
            if ("token/refresh".equals(endpoint) || "login".equals(endpoint)) {
                // Auth responses are metadata-only, not merely a best-effort
                // redacted body. Future credential field names must not leak.
                JSONObject summary = new JSONObject();
                for (String key : new String[]{"ok", "tier", "integrityStale", "error", "code", "reason", "status"}) {
                    if (parsed.has(key)) summary.put(key, redact(parsed.get(key), 1));
                }
                summary.put("has_access", parsed.has("access") || parsed.has("accessToken"));
                summary.put("has_refresh", parsed.has("refresh") || parsed.has("refreshToken"));
                summary.put("auth_values_omitted", true);
                safe = summary;
            } else {
                safe = redact(parsed, 0);
            }
        }
        JSONObject record = new JSONObject();
        record.put("time_ms", System.currentTimeMillis());
        record.put("endpoint", GatePolicy.endpoint(endpoint));
        record.put("status", status);
        record.put("mocked", mocked);
        record.put("body", safe);
        byte[] line = (record.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        File parent = output.getParentFile();
        if ((parent.isDirectory() || parent.mkdirs()) && output.length() + line.length <= MAX_FILE_BYTES) {
            try (FileOutputStream stream = new FileOutputStream(output, true)) {
                stream.write(line);
            }
        }
        // A bounded preview appears in LSPosed too; the private JSONL holds the
        // complete redacted record (subject to the limits above).
        String preview = String.valueOf(safe);
        return preview.length() > 1800 ? preview.substring(0, 1800) + "<truncated>" : preview;
    }

    private static Object redact(Object value, int depth) throws Exception {
        if (depth > 8) return "<depth-limit>";
        if (value instanceof JSONObject) {
            JSONObject result = new JSONObject();
            Iterator<String> keys = ((JSONObject) value).keys();
            int count = 0;
            while (keys.hasNext()) {
                if (++count > 64) { result.put("_truncated", true); break; }
                String key = keys.next();
                result.put(GatePrivacy.text(key), GatePrivacy.sensitive(key) ? "<redacted>"
                    : redact(((JSONObject) value).get(key), depth + 1));
            }
            return result;
        }
        if (value instanceof JSONArray) {
            JSONArray result = new JSONArray();
            JSONArray source = (JSONArray) value;
            for (int i = 0; i < Math.min(source.length(), 32); i++) {
                result.put(redact(source.get(i), depth + 1));
            }
            if (source.length() > 32) result.put("<truncated>");
            return result;
        }
        return value instanceof String ? GatePrivacy.text((String) value) : value;
    }
}
