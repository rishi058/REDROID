package com.recon.pgstrace;

import android.util.Log;
import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.callbacks.XC_LoadPackage;
import java.io.FileInputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Read-only observation before Phonesky normalizes its PGS response.
 * No method result, argument, protobuf, Binder bundle, key or token is modified.
 * The obfuscated mapping is accepted only for the exact inspected Play APK.
 */
public final class Hook implements IXposedHookLoadPackage {
    private static final String FLAG = "/data/local/tmp/pgstrace.enabled";
    private static final String TAG = "PGSTrace";
    private final AtomicInteger events = new AtomicInteger();

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lp) {
        if (!TracePolicy.isAllowedPlayStoreProcess(lp.packageName, lp.processName)
                || !TracePolicy.isEnabledFlag(readFlag())) return;
        try {
            if (lp.appInfo == null || !TracePolicy.isVerifiedPlayStore(
                    lp.packageName, lp.processName, sha256(lp.appInfo.sourceDir))) {
                emit("SKIP playApkHashMismatch=true");
                return;
            }
            install(lp.classLoader);
            emit("ACTIVE playBuild=85322340 process=" + lp.processName
                + " target=com.diskwalaapp:356 readOnly=true payloadLogging=false");
        } catch (Throwable error) {
            emit("SKIP mappingUnavailable errorClass=" + error.getClass().getName());
        }
    }

    private void install(ClassLoader loader) throws Exception {
        // Raw DEX descriptors are Latox;, Lcbhr;, etc. "defpackage" is a JADX alias.
        final Class<?> parser = Class.forName("atox", false, loader);
        final Class<?> response = Class.forName("cbhr", false, loader);
        final Class<?> entry = Class.forName("cbhs", false, loader);
        final Class<?> keyResponse = Class.forName("cbhq", false, loader);
        final Class<?> byteString = Class.forName("cbma", false, loader);
        final Field requestPackage = field(parser, "a", String.class);
        final Field requestVersion = field(parser, "b", int.class);
        final Field responseItems = field(response, "b", null);
        if (!List.class.isAssignableFrom(responseItems.getType())) {
            throw new NoSuchFieldException("response list type");
        }
        final Field responseCase = field(entry, "b", int.class);
        final Field responseValue = field(entry, "c", Object.class);
        final Field status = field(keyResponse, "d", int.class);
        final Field keyCase = field(keyResponse, "b", int.class);
        final Field keyObject = field(keyResponse, "c", Object.class);
        final Field presenceBits = field(keyResponse, "f", int.class);
        final Field encryptedKeyData = field(keyResponse, "e", byteString);
        final Method byteLength = byteString.getDeclaredMethod("d");
        if (byteLength.getReturnType() != int.class) {
            throw new NoSuchMethodException("byte length return type");
        }
        byteLength.setAccessible(true);
        Method process = parser.getDeclaredMethod("a", Object.class);
        if (!"bsce".equals(process.getReturnType().getName())) {
            throw new NoSuchMethodException("parser return type");
        }

        XposedBridge.hookMethod(process, new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam p) {
                try {
                    String pkg = (String) requestPackage.get(p.thisObject);
                    int version = requestVersion.getInt(p.thisObject);
                    if (!TracePolicy.isTargetDiskWala(pkg, version)
                            || !TracePolicy.isEnabledFlag(readFlag())) return;
                    if (events.incrementAndGet() > TracePolicy.MAX_EVENTS) return;
                    Object raw = p.args[0];
                    if (!response.isInstance(raw)) {
                        emit("PGS target=com.diskwalaapp:356 responseTypeMatched=false");
                        return;
                    }
                    List<?> items = (List<?>) responseItems.get(raw);
                    int count = items == null ? -1 : items.size();
                    if (count != 1 || !entry.isInstance(items.get(0))) {
                        emit("PGS target=com.diskwalaapp:356 responseItems=" + count
                            + " shapeMatched=false");
                        return;
                    }
                    Object item = items.get(0);
                    int itemCase = responseCase.getInt(item);
                    Object value = responseValue.get(item);
                    if (itemCase != 4 || !keyResponse.isInstance(value)) {
                        emit("PGS target=com.diskwalaapp:356 responseItems=1 responseCase="
                            + itemCase + " keyResponseMatched=false");
                        return;
                    }
                    int rawStatus = status.getInt(value);
                    int rawKeyCase = keyCase.getInt(value);
                    // d() is ByteString.size(); never call C() (toByteArray) or toString().
                    Object protectionKey = keyObject.get(value);
                    boolean keyObjectPresent = protectionKey != null;
                    int protectionKeyBytes = byteString.isInstance(protectionKey)
                        ? (Integer) byteLength.invoke(protectionKey) : 0;
                    Object data = encryptedKeyData.get(value);
                    int encryptedKeyDataBytes = byteString.isInstance(data)
                        ? (Integer) byteLength.invoke(data) : 0;
                    int bits = presenceBits.getInt(value);
                    emit("PGS target=com.diskwalaapp:356 responseItems=1 responseCase=4"
                        + " rawStatus=" + rawStatus
                        + " status=" + TracePolicy.statusLabel(rawStatus)
                        + " keyCase=" + rawKeyCase
                        + " wrappedFieldSelected=" + (rawKeyCase == 3)
                        + " unwrappedFieldSelected=" + (rawKeyCase == 6)
                        + " keyObjectPresent=" + keyObjectPresent
                        + " protectionKeyBytes=" + protectionKeyBytes
                        + " encryptedKeyDataBytes=" + encryptedKeyDataBytes
                        + " encryptedKeyDataFieldPresent=" + ((bits & 2) != 0)
                        + " presenceBits=" + bits);
                } catch (Throwable error) {
                    // A failed observation must not change Phonesky's original outcome.
                    if (events.incrementAndGet() <= TracePolicy.MAX_EVENTS) {
                        emit("OBSERVE_ERROR errorClass=" + error.getClass().getName());
                    }
                }
            }
        });
    }

    private static Field field(Class<?> owner, String name, Class<?> expected) throws Exception {
        Field field = owner.getDeclaredField(name);
        if (expected != null && field.getType() != expected) {
            throw new NoSuchFieldException("unexpected field type");
        }
        field.setAccessible(true);
        return field;
    }

    private static String readFlag() {
        try (FileInputStream input = new FileInputStream(FLAG)) {
            return input.read() == '1' && input.read() == -1 ? "1" : "";
        } catch (Exception disabled) {
            return "";
        }
    }

    private static String sha256(String path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (FileInputStream input = new FileInputStream(path)) {
            byte[] buffer = new byte[65536];
            int length;
            while ((length = input.read(buffer)) != -1) digest.update(buffer, 0, length);
        }
        StringBuilder hex = new StringBuilder(64);
        for (byte value : digest.digest()) {
            hex.append(Character.forDigit((value >>> 4) & 15, 16));
            hex.append(Character.forDigit(value & 15, 16));
        }
        return hex.toString();
    }

    private static void emit(String message) {
        Log.i(TAG, message);
        XposedBridge.log("[" + TAG + "] " + message);
    }
}
