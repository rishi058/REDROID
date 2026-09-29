package com.recon.dw26gate;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import org.json.JSONObject;

/** Authenticated one-request-per-connection signing service reachable only through ADB forwarding. */
final class SignerBridge implements Closeable {
    interface Logger { void log(String message); }

    static final int PORT = 39026;
    private static final int SOCKET_TIMEOUT_MS = 5000;
    private final Logger logger;
    private final String secret;
    private final AndroidKeyStoreSigner signer = new AndroidKeyStoreSigner();
    private final ServerSocket server;
    private volatile boolean closed;

    static SignerBridge start(String dataDir, Logger logger) throws Exception {
        SignerBridge bridge = new SignerBridge(dataDir, logger);
        Thread thread = new Thread(bridge::serve, "dw26-signer-bridge");
        thread.setDaemon(true);
        thread.start();
        return bridge;
    }

    private SignerBridge(String dataDir, Logger logger) throws Exception {
        this.logger = logger;
        this.secret = loadOrCreateSecret(dataDir);
        this.server = new ServerSocket(PORT, 4, InetAddress.getByName("127.0.0.1"));
        this.server.setReuseAddress(true);
    }

    private void serve() {
        while (!closed) {
            try (Socket socket = server.accept()) {
                socket.setSoTimeout(SOCKET_TIMEOUT_MS);
                handle(socket);
            } catch (Exception error) {
                if (!closed) logger.log("SIGNER request failed class=" + error.getClass().getName());
            }
        }
    }

    private void handle(Socket socket) throws Exception {
        JSONObject request = new JSONObject(new String(readFrame(socket.getInputStream()), StandardCharsets.UTF_8));
        String supplied = request.optString("secret", "");
        if (!MessageDigest.isEqual(secret.getBytes(StandardCharsets.UTF_8), supplied.getBytes(StandardCharsets.UTF_8))) {
            write(socket.getOutputStream(), failure("unauthorized"));
            return;
        }
        String op = request.optString("op", "");
        if ("status".equals(op)) {
            JSONObject status = new JSONObject();
            status.put("ok", true);
            status.put("alias_present", signer.aliasPresent());
            status.put("port", PORT);
            write(socket.getOutputStream(), status);
            return;
        }
        if (!"sign".equals(op)) {
            write(socket.getOutputStream(), failure("operation_not_allowed"));
            return;
        }
        String path = request.optString("path", "");
        if (!SignerPolicy.allowedPath(path)) {
            write(socket.getOutputStream(), failure("path_not_allowed"));
            return;
        }
        byte[] body;
        try {
            body = Base64.getDecoder().decode(request.getString("body_b64"));
        } catch (Exception invalidBody) {
            write(socket.getOutputStream(), failure("body_invalid"));
            return;
        }
        if (body.length > SignerPolicy.MAX_BODY_BYTES) {
            write(socket.getOutputStream(), failure("body_too_large"));
            return;
        }
        JSONObject proof = signer.sign(path, body);
        proof.put("ok", true);
        write(socket.getOutputStream(), proof);
    }

    private static byte[] readFrame(InputStream input) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        while (output.size() <= SignerPolicy.MAX_FRAME_BYTES) {
            int value = input.read();
            if (value == -1 || value == '\n') break;
            output.write(value);
        }
        if (output.size() == 0 || output.size() > SignerPolicy.MAX_FRAME_BYTES) {
            throw new IllegalArgumentException("frame_size_invalid");
        }
        return output.toByteArray();
    }

    private static void write(OutputStream output, JSONObject value) throws Exception {
        output.write((value.toString() + "\n").getBytes(StandardCharsets.UTF_8));
        output.flush();
    }

    private static JSONObject failure(String code) throws Exception {
        JSONObject value = new JSONObject();
        value.put("ok", false);
        value.put("error", code);
        return value;
    }

    private static String loadOrCreateSecret(String dataDir) throws Exception {
        File directory = new File(new File(dataDir, "files"), "dw26gate");
        if (!(directory.isDirectory() || directory.mkdirs())) {
            throw new IllegalStateException("secret_directory_unavailable");
        }
        File file = new File(directory, "signer.secret");
        if (file.isFile()) {
            byte[] bytes = readSecret(file);
            String existing = new String(bytes, StandardCharsets.US_ASCII).trim();
            if (existing.length() >= 43 && existing.length() <= 128) return existing;
            throw new IllegalStateException("secret_invalid");
        }
        byte[] random = new byte[32];
        new SecureRandom().nextBytes(random);
        String created = Base64.getUrlEncoder().withoutPadding().encodeToString(random);
        try (FileOutputStream output = new FileOutputStream(file)) {
            output.write((created + "\n").getBytes(StandardCharsets.US_ASCII));
            output.getFD().sync();
        }
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setReadable(true, true);
        file.setWritable(true, true);
        return created;
    }

    private static byte[] readSecret(File file) throws Exception {
        if (file.length() <= 0 || file.length() > 256) throw new IllegalStateException("secret_size_invalid");
        byte[] bytes = new byte[(int) file.length()];
        try (FileInputStream input = new FileInputStream(file)) {
            int offset = 0;
            while (offset < bytes.length) {
                int read = input.read(bytes, offset, bytes.length - offset);
                if (read < 0) break;
                offset += read;
            }
            if (offset != bytes.length) throw new IllegalStateException("secret_read_failed");
        }
        return bytes;
    }

    @Override public void close() throws IOException {
        closed = true;
        server.close();
    }
}
