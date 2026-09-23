package com.recon.dw26gate;

import de.robv.android.xposed.XposedHelpers;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONObject;

/** Explicit client-side fixtures; the real response is always captured first. */
final class MockResponses {
    static final String FILE = "/data/local/tmp/dw26gate-mocks.json";
    private final Map<String, JSONObject> responses = new HashMap<>();

    static MockResponses load() throws Exception {
        MockResponses result = new MockResponses();
        if (!new File(FILE).isFile()) return result;
        String text;
        try (FileInputStream in = new FileInputStream(FILE);
                ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[1024];
            int length;
            while ((length = in.read(buffer)) > 0) {
                out.write(buffer, 0, length);
                if (out.size() > 16384) throw new IllegalArgumentException("Config too large");
            }
            text = new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
        JSONObject config = new JSONObject(text);
        if (!Boolean.TRUE.equals(config.opt("enabled"))) return result;
        JSONObject entries = config.getJSONObject("responses");
        Iterator<String> keys = entries.keys();
        while (keys.hasNext()) {
            String path = keys.next();
            if (!GatePolicy.mockAllowed(GateMode.MOCK, path)) {
                throw new IllegalArgumentException("Endpoint is not allowlisted");
            }
            JSONObject entry = entries.getJSONObject(path);
            Object status = entry.get("status");
            if (!(status instanceof Integer) || (Integer) status < 200 || (Integer) status > 599) {
                throw new IllegalArgumentException("Invalid fixture HTTP status");
            }
            if (entry.getJSONObject("body").toString().length() > 8192) {
                throw new IllegalArgumentException("Fixture body too large");
            }
            result.responses.put(path, entry);
        }
        return result;
    }

    int size() { return responses.size(); }

    Object response(String endpoint, Object worker, Class<?> responseClass) throws Exception {
        JSONObject entry = responses.get(endpoint);
        if (entry == null) return null;
        Object api = XposedHelpers.getObjectField(worker, "v");
        Object jsonParser = XposedHelpers.getObjectField(api, "c");
        Object body = XposedHelpers.callMethod(jsonParser, "d", entry.getJSONObject("body").toString());
        Class<?> bodyClass = Class.forName("kotlinx.serialization.json.JsonObject", false,
            responseClass.getClassLoader());
        if (!bodyClass.isInstance(body)) throw new IllegalArgumentException("Invalid fixture body type");
        LinkedHashMap<String, String> headers = new LinkedHashMap<>();
        headers.put("content-type", "application/json");
        return responseClass.getDeclaredConstructor(int.class, bodyClass, LinkedHashMap.class)
            .newInstance(entry.getInt("status"), body, headers);
    }
}
