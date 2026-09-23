package com.recon.dw26gate;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;
import java.io.FileInputStream;
import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Exact-APK gate probe. Observe by default. Local mode only renders the normal
 * signed-out UI, without changing the launch state. Mock mode additionally
 * requires an enabled fixture file; its client-only responses are not server
 * attestations, credentials, or evidence that authentication succeeded.
 */
public final class Hook implements IXposedHookLoadPackage {
    private static final String MODE_FILE = "/data/local/tmp/dw26gate.mode";
    private static final int LOG_LIMIT = 160;
    private final AtomicInteger logs = new AtomicInteger();
    private final AtomicInteger requests = new AtomicInteger();
    private final AtomicInteger keyLogs = new AtomicInteger();
    private final List<XC_MethodHook.Unhook> installed = new ArrayList<>();
    private final ThreadLocal<Object> signInModel = new ThreadLocal<>();
    private volatile WeakReference<Object> existingSession = new WeakReference<>(null);
    private volatile WeakReference<Object> existingSignInModel = new WeakReference<>(null);
    private ResponseBodies captures;
    private VaultKeys keys;
    private MockResponses mocks;
    private String lastLaunchState;
    private GateMode mode = GateMode.OBSERVE;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lp) {
        if (!GatePolicy.PACKAGE.equals(lp.packageName)
                || !GatePolicy.PACKAGE.equals(lp.processName)) return;
        mode = readMode();
        log("mode=" + mode + " target=" + GatePolicy.TARGET_VERSION + "/"
            + GatePolicy.TARGET_VERSION_CODE);
        if (mode == GateMode.OFF) return;
        try {
            if (lp.appInfo == null || !GatePolicy.BASE_SHA256.equals(sha256(lp.appInfo.sourceDir))) {
                log("SKIP: APK digest does not match tested " + GatePolicy.TARGET_VERSION
                    + "; no hooks installed");
                return;
            }
            captures = new ResponseBodies(lp.appInfo.dataDir);
            keys = new VaultKeys(lp.appInfo.dataDir);
            if (mode == GateMode.MOCK) {
                try {
                    mocks = MockResponses.load();
                    log("MOCK_FIXTURES count=" + mocks.size()
                        + " (client-only; real responses still captured)");
                } catch (Exception invalidConfig) {
                    log("MOCK_DISABLED invalid config class=" + type(invalidConfig));
                }
            }
            install(lp.classLoader);
            log("ACTIVE hooks=" + installed.size() + " digest=verified"
                + " tokens=untouched bodyCapture=redacted");
        } catch (Throwable error) {
            // Fail open as a group; don't leave a partial experiment installed.
            for (XC_MethodHook.Unhook hook : installed) {
                try { hook.unhook(); } catch (Throwable ignored) {}
            }
            installed.clear();
            log("SKIP: signature mismatch or install failure class=" + type(error));
        }
    }

    private void install(ClassLoader loader) throws Exception {
        Class<?> apiWorker = resolve("E5.b", loader);
        Class<?> apiResponse = resolve("E5.g", loader);
        Class<?> apiError = resolve("E5.f", loader);
        Class<?> classifier = resolve("B5.P", loader);
        Class<?> session = resolve("B5.f", loader);
        Class<?> unsupported = resolve("B5.a", loader);
        Class<?> badId = resolve("C5.u", loader);
        Class<?> idProvider = resolve("C5.e", loader);
        Class<?> signIn = resolve("O5.u0", loader);

        // These are raw DEX names, not JADX's case-insensitive aliases.
        requireField(apiWorker, "x", String.class);
        requireField(apiResponse, "a", int.class);
        requireField(apiError, "b", int.class);
        requireField(apiError, "c", String.class);
        Method transaction = apiWorker.getDeclaredMethod("invokeSuspend", Object.class);
        Method classify = classifier.getDeclaredMethod("a", Throwable.class);
        Method wrap = session.getDeclaredMethod("c", Throwable.class);
        if (!"B5.d".equals(classify.getReturnType().getName())
                || wrap.getReturnType() != Throwable.class) {
            throw new NoSuchMethodException("Gate classifier signature changed");
        }

        hook(transaction, new SafeHook() {
            @Override void before(MethodHookParam p) {
                int id = requests.incrementAndGet();
                p.setObjectExtra("dw26-id", id);
                p.setObjectExtra("dw26-start", System.nanoTime());
                log("HTTP begin id=" + id + " endpoint="
                    + GatePolicy.endpoint(XposedHelpers.getObjectField(p.thisObject, "x")));
            }
            @Override void after(MethodHookParam p) throws Throwable {
                Object started = p.getObjectExtra("dw26-start");
                long elapsed = started instanceof Long
                    ? (System.nanoTime() - (Long) started) / 1_000_000L : -1;
                String prefix = "HTTP end id=" + p.getObjectExtra("dw26-id")
                    + " endpoint=" + GatePolicy.endpoint(
                        XposedHelpers.getObjectField(p.thisObject, "x"))
                    + " elapsedMs=" + elapsed;
                if (p.hasThrowable()) {
                    log(prefix + " failure=" + errorShape(p.getThrowable()));
                } else if (p.getResult() != null && apiResponse.isInstance(p.getResult())) {
                    Object response = p.getResult();
                    String endpoint = GatePolicy.endpoint(
                        XposedHelpers.getObjectField(p.thisObject, "x"));
                    log(prefix + " status=" + XposedHelpers.getIntField(response, "a")
                        + " error=" + responseError(response));
                    if (!"<other>".equals(endpoint) || XposedHelpers.getIntField(response, "a") >= 400) {
                        capture(response, endpoint, false);
                        if (mocks != null && GatePolicy.mockAllowed(mode, endpoint)) {
                            Object replacement = mocks.response(endpoint, p.thisObject, apiResponse);
                            if (replacement != null) {
                                capture(replacement, endpoint, true);
                                p.setResult(replacement);
                                log("MOCK_CLIENT_RESPONSE endpoint=" + endpoint
                                    + " realStatus=" + XposedHelpers.getIntField(response, "a")
                                    + " fixtureStatus=" + XposedHelpers.getIntField(replacement, "a")
                                    + " serverDecision=UNCHANGED");
                            }
                        }
                    }
                } else {
                    log(prefix + " resultClass=" + type(p.getResult()));
                }
            }
        });

        installed.add(XposedBridge.hookMethod(apiError.getDeclaredConstructor(int.class, String.class),
            new SafeHook() {
                @Override void after(MethodHookParam p) {
                    log("API_ERROR status=" + p.args[0] + " code=" + GatePolicy.code(p.args[1]));
                }
            }));

        hook(classify, new SafeHook() {
            @Override void after(MethodHookParam p) {
                Object result = p.getResult();
                String category = result instanceof Enum<?> ? ((Enum<?>) result).name() : type(result);
                log("CLASSIFY " + errorShape(p.args[0]) + " -> " + category);
            }
        });

        hook(wrap, new SafeHook() {
            @Override void after(MethodHookParam p) {
                Object source = p.args[0];
                log("WRAP source=" + errorShape(source) + " result=" + type(p.getResult()));
            }
        });

        installed.addAll(XposedBridge.hookAllConstructors(unsupported, new SafeHook() {
            @Override void after(MethodHookParam p) {
                log("UNSUPPORTED_EXCEPTION B5.a constructed caller=" + caller());
            }
        }));
        installed.addAll(XposedBridge.hookAllConstructors(badId, new SafeHook() {
            @Override void after(MethodHookParam p) {
                log("LOCAL_ID_REJECTION C5.u constructed caller=" + caller());
            }
        }));

        hook(idProvider.getDeclaredMethod("a"), new SafeHook() {
            @Override void after(MethodHookParam p) {
                Object result = p.getResult();
                log("ANDROID_ID result=" + (p.hasThrowable() ? errorShape(p.getThrowable())
                    : result instanceof String ? "present length=" + ((String) result).length()
                    : type(result)));
            }
        });

        hook(signIn.getDeclaredMethod("invokeSuspend", Object.class), new SafeHook() {
            @Override void after(MethodHookParam p) {
                Object model = XposedHelpers.getObjectField(p.thisObject, "y");
                Object flow = XposedHelpers.getObjectField(model, "e");
                Object state = XposedHelpers.callMethod(flow, "getValue");
                // Only the type, never the state's toString() (could contain a message).
                log("SIGN_IN_STATE type=" + type(state) + " failure=" + type(p.getThrowable()));
            }
        });
        installDecryptOracle(loader);
        installLaunchPresentation(loader);
    }

    /**
     * 26.2 response-key oracle. Every encrypted response field (the np_lelo
     * {@code fileInfo} blob and the {@code url} nested inside it) is opened by
     * C5.c.a(String ciphertext, String password). The password argument is the
     * live content key and the return value is the plaintext, so this single
     * hook recovers the outer fileInfo key and the inner (derived) url key
     * together. Read-only: it never alters args or result.
     */
    private void installDecryptOracle(ClassLoader loader) {
        try {
            Class<?> crypto = resolve("C5.c", loader);
            hook(crypto.getDeclaredMethod("a", String.class, String.class), keyCapture("decrypt"));
            try {
                hook(crypto.getDeclaredMethod("b", String.class, String.class), keyCapture("encrypt"));
            } catch (Throwable noEncrypt) {
                log("C5.c.b encrypt-capture absent class=" + type(noEncrypt));
            }
            log("C5.c key oracle installed (26.2 content keys -> cache/dw26gate-keys.jsonl)");
        } catch (Throwable notThisBuild) {
            log("key oracle NOT installed (C5.c absent) class=" + type(notThisBuild));
        }
    }

    // C5.c.a(ciphertext, password) -> plaintext  and  C5.c.b(plaintext, password)
    // -> ciphertext. arg[1] is the live key either way; reading it here answers
    // the key-source question at runtime even though PairIP hides the
    // key-producing code (E5.a/E5.d) inside the pairipcore native VM, out of the
    // static decompile. Read-only: never alters args or result.
    private SafeHook keyCapture(final String op) {
        final boolean decrypt = "decrypt".equals(op);
        return new SafeHook() {
            @Override void after(MethodHookParam p) {
                String key = p.args[1] == null ? "none" : p.args[1].toString();
                String input = p.args[0] == null ? "none" : p.args[0].toString();
                // C5.c.a returns null for a non-Salted__ input or wrong key.
                boolean failed = p.hasThrowable() || (decrypt && p.getResult() == null);
                String output = p.hasThrowable() ? errorShape(p.getThrowable())
                    : p.getResult() == null ? null : p.getResult().toString();
                String plaintext = decrypt ? output : input;
                keys.record(op, key, input, output, failed);
                keyLog("KEY op=" + op + " role=" + VaultKeys.role(plaintext, failed)
                    + " key=" + key + " keyLen=" + key.length()
                    + " in=" + preview(input, 24) + " out=" + preview(output, 96));
            }
        };
    }

    private void installLaunchPresentation(ClassLoader loader) throws Exception {
        // JADX calls raw O5.h "EnumC0447h" on case-insensitive Windows. Never
        // use that generated alias as the runtime class name.
        Class<?> check = resolve("O5.h", loader);
        Class<?> model = resolve("O5.w0", loader);
        Class<?> session = resolve("B5.f", loader);
        Class<?> composer = resolve("b0.j", loader);
        Class<?> route = resolve("L5.i", loader);
        Class<?> renderer = resolve("M5.F0", loader);
        Method signedOut = resolve("M5.D3", loader).getDeclaredMethod("e", model, composer, int.class);
        Method routeMethod = route.getDeclaredMethod("a", model, resolve("O5.f", loader),
            resolve("K5.e", loader), resolve("O5.h0", loader), resolve("L5.s", loader),
            composer, int.class);
        hook(session.getDeclaredMethod("e", boolean.class, resolve("qb.d", loader)), new SafeHook() {
            @Override void before(MethodHookParam p) {
                existingSession = new WeakReference<>(p.thisObject);
            }
        });
        installed.add(XposedBridge.hookMethod(model.getDeclaredConstructor(session), new SafeHook() {
            @Override void after(MethodHookParam p) {
                existingSignInModel = new WeakReference<>(p.thisObject);
            }
        }));
        hook(routeMethod, new SafeHook() {
            @Override void before(MethodHookParam p) {
                p.setObjectExtra("dw26-prior-model", signInModel.get());
                signInModel.set(p.args[0]);
            }
            @Override void after(MethodHookParam p) {
                Object previous = p.getObjectExtra("dw26-prior-model");
                if (previous == null) signInModel.remove(); else signInModel.set(previous);
            }
        });
        hook(renderer.getDeclaredMethod("a", check, resolve("zb.a", loader), composer, int.class),
            new SafeHook() {
                @Override void before(MethodHookParam p) throws Throwable {
                    String state = p.args[0] instanceof Enum<?> ? ((Enum<?>) p.args[0]).name() : "unknown";
                    if (!state.equals(lastLaunchState)) {
                        lastLaunchState = state;
                        log("LAUNCH_GATE state=" + state);
                    }
                    Object currentModel = signInModel.get();
                    if (currentModel == null) currentModel = existingSignInModel.get();
                    if (mode == GateMode.LOCAL && "UNSUPPORTED".equals(state) && currentModel == null) {
                        Object realSession = existingSession.get();
                        if (session.isInstance(realSession)) {
                            // The launch gate can run before the sign-in UI's
                            // ViewModel is created. Attach a UI model to the REAL
                            // existing session; don't invent credentials/state.
                            currentModel = model.getDeclaredConstructor(session).newInstance(realSession);
                            existingSignInModel = new WeakReference<>(currentModel);
                        }
                    }
                    if (GatePolicy.showSignedOut(mode, state, model.isInstance(currentModel))) {
                        // Only choose a different existing Composable. No flow,
                        // key alias, session, API result or attestation is altered.
                        signedOut.invoke(null, currentModel, p.args[2], 0);
                        p.setResult(null);
                        log("LOCAL_PRESENTATION signed-out UI rendered; actual launch state remains " + state);
                    } else if (mode == GateMode.LOCAL && "UNSUPPORTED".equals(state)) {
                        log("LOCAL_PRESENTATION skipped: live SessionViewModel unavailable");
                    }
                }
            });
    }

    private void capture(Object response, String endpoint, boolean mocked) {
        try {
            String body = captures.record(endpoint, XposedHelpers.getIntField(response, "a"),
                XposedHelpers.getObjectField(response, "b"), mocked);
            log("BODY endpoint=" + endpoint + " mocked=" + mocked + " json=" + body);
        } catch (Exception captureError) {
            // Capture failure must not change normal request/result handling.
            log("BODY_CAPTURE_FAILED class=" + type(captureError));
        }
    }

    private String responseError(Object response) {
        Object body = XposedHelpers.getObjectField(response, "b");
        Object error = body instanceof Map<?, ?> ? ((Map<?, ?>) body).get("error") : null;
        if (error != null) {
            try { return GatePolicy.code(XposedHelpers.callMethod(error, "c")); }
            catch (Throwable ignored) { return "<redacted>"; }
        }
        Object header = XposedHelpers.callMethod(response, "a", "prm-status");
        if (header == null) header = XposedHelpers.callMethod(response, "a", "tier-status");
        return GatePolicy.code(header);
    }

    private String errorShape(Object error) {
        if (error != null && "E5.f".equals(error.getClass().getName())) {
            return "E5.f status=" + XposedHelpers.getIntField(error, "b")
                + " code=" + GatePolicy.code(XposedHelpers.getObjectField(error, "c"));
        }
        return type(error);
    }

    private void hook(Method method, XC_MethodHook callback) {
        installed.add(XposedBridge.hookMethod(method, callback));
    }

    private abstract class SafeHook extends XC_MethodHook {
        void before(MethodHookParam p) throws Throwable {}
        void after(MethodHookParam p) throws Throwable {}
        @Override protected final void beforeHookedMethod(MethodHookParam p) {
            try { before(p); } catch (Throwable error) { log("PROBE_ERROR before=" + type(error)); }
        }
        @Override protected final void afterHookedMethod(MethodHookParam p) {
            try { after(p); } catch (Throwable error) { log("PROBE_ERROR after=" + type(error)); }
        }
    }

    private void log(String message) {
        int sequence = logs.incrementAndGet();
        if (sequence > LOG_LIMIT) return;
        XposedBridge.log("[DW26Gate][" + sequence + "]["
            + android.os.SystemClock.elapsedRealtime() + "ms] " + message);
    }

    // Recovered keys get their own budget so a burst of decrypt calls at launch
    // can't push the key lines past the shared LOG_LIMIT. The JSONL file is the
    // authoritative record; this is the quick-look copy.
    private void keyLog(String message) {
        if (keyLogs.incrementAndGet() > 80) return;
        XposedBridge.log("[DW26Gate][key] " + message);
    }

    private static String preview(String value, int max) {
        if (value == null) return "none";
        String flat = value.replace('\n', ' ').replace('\r', ' ');
        return flat.length() > max ? flat.substring(0, max) + "..." : flat;
    }

    private static GateMode readMode() {
        try (FileInputStream in = new FileInputStream(MODE_FILE)) {
            byte[] bytes = new byte[65];
            int length = in.read(bytes);
            if (length < 0 || length > 64) return GateMode.OBSERVE;
            return GateMode.parse(new String(bytes, 0, length, java.nio.charset.StandardCharsets.UTF_8));
        } catch (Exception ignored) {
            return GateMode.OBSERVE;
        }
    }

    private static Class<?> resolve(String name, ClassLoader loader) throws ClassNotFoundException {
        return Class.forName(name, false, loader);
    }

    private static void requireField(Class<?> owner, String name, Class<?> expected) throws Exception {
        Field field = owner.getDeclaredField(name);
        if (field.getType() != expected) throw new NoSuchFieldException(owner.getName() + '.' + name);
    }

    private static String type(Object value) {
        return value == null ? "none" : value.getClass().getName();
    }

    private static String caller() {
        StringBuilder result = new StringBuilder();
        for (StackTraceElement frame : Thread.currentThread().getStackTrace()) {
            String name = frame.getClassName();
            if (!(name.startsWith("A5.") || name.startsWith("B5.")
                    || name.startsWith("C5.") || name.startsWith("E5.") || name.startsWith("O5."))) continue;
            if (result.length() > 0) result.append('>');
            result.append(name).append('#').append(frame.getMethodName());
            if (result.length() > 180) break;
        }
        return result.toString();
    }

    private static String sha256(String path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (FileInputStream in = new FileInputStream(path)) {
            byte[] bytes = new byte[65536];
            int length;
            while ((length = in.read(bytes)) >= 0) if (length > 0) digest.update(bytes, 0, length);
        }
        char[] hex = "0123456789abcdef".toCharArray();
        StringBuilder result = new StringBuilder(64);
        for (byte b : digest.digest()) result.append(hex[(b & 0xff) >>> 4]).append(hex[b & 15]);
        return result.toString();
    }
}
