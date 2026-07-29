package com.recon.talsecbypass;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/* Targeted freeRASP/Talsec reaction guard for com.target-appapp.
   The app obfuscated the freeRASP SDK, so generic unrasp couldn't hook it. The
   RN bridge class + its @ReactMethod names are preserved by React Native.

   Keep native RASP initialization active: AppiCrypt can encode its execution
   and integrity state in the server-verified cryptogram. Only the app's kill,
   teardown, and JS threat-reaction paths are guarded below. */
public class Hook implements IXposedHookLoadPackage {
    private static final String TAG = "[TalsecKill] ";
    private static final String TARGET_PACKAGE = "com.target-appapp";
    private static final String SPOOF_DEVICE_ID = "accepted-device-id";
    private static final String DEVICE_ID_PLACEHOLDER_PREFIX = "accepted-device-";
    private static final String PLUGIN = "com.talsecreactnativesecurityplugin.TalsecReactNativeSecurityPluginModule";
    private static final boolean PASSIVE_INTEGRITY_TEST = false;
    private static final boolean BYPASS_RASP_START = false;
    private static final boolean LOG_NATIVE_THREATS = true;
    private static final boolean LOG_APPICRYPT_INPUTS = true;
    private static final boolean LOG_INSTALL_SOURCE = true;
    private static final boolean SPOOF_APPICRYPT_CHECKS = true;

    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lp) throws Throwable {
        if (!TARGET_PACKAGE.equals(lp.packageName)) return;
        final ClassLoader cl = lp.classLoader;
        XposedBridge.log(TAG + "loaded in " + lp.packageName);

        // A/B mode: leave the target completely untouched so AppiCrypt can mint
        // a cryptogram without any Talsec method or Android framework hook.
        // target-app may later enforce its normal self-termination behavior.
        if (PASSIVE_INTEGRITY_TEST) {
            XposedBridge.log(TAG + "passive integrity test: zero hooks installed");
            return;
        }

        // Diagnostic only: observe Talsec's typed native callbacks before the
        // React Native event channel. This logs names, never event payloads,
        // cryptograms, nonces, tokens, or vault values.
        if (LOG_NATIVE_THREATS) {
            hookThreatCallback(cl, "Nd.w", "a", "Automation");
            hookThreatCallback(cl, "Nd.w", "b", "Debug");
            hookThreatCallback(cl, "Nd.w", "c", "DeviceBinding");
            hookThreatCallback(cl, "Nd.w", "d", "Simulator");
            hookThreatCallback(cl, "Nd.w", "e", "Hooks");
            hookThreatCallback(cl, "Nd.w", "f", "LocationSpoofing");
            hookThreatCallback(cl, "Nd.w", "h", "MultiInstance");
            hookThreatCallback(cl, "Nd.w", "i", "ObfuscationIssues");
            hookThreatCallback(cl, "Nd.w", "j", "PrivilegedAccess");
            hookThreatCallback(cl, "Nd.w", "k", "ScreenRecording");
            hookThreatCallback(cl, "Nd.w", "l", "Screenshot");
            hookThreatCallback(cl, "Nd.w", "m", "AppIntegrity");
            hookThreatCallback(cl, "Nd.w", "n", "TimeSpoofing");
            hookThreatCallback(cl, "Nd.w", "o", "UnsecureWifi");
            hookThreatCallback(cl, "Nd.w", "p", "UnofficialStore");
            hookThreatCallback(cl, "Nd.u", "a", "ADBEnabled");
            hookThreatCallback(cl, "Nd.u", "b", "DevMode");
            hookThreatCallback(cl, "Nd.u", "c", "SecureHardwareNotAvailable");
            hookThreatCallback(cl, "Nd.u", "d", "SystemVPN");
            hookThreatCallback(cl, "Nd.u", "e", "Passcode");
        }

        if (LOG_APPICRYPT_INPUTS) {
            hookAppiCryptInputs(cl);
        }
        if (LOG_INSTALL_SOURCE) {
            hookInstallSource(cl);
        }
        if (!SPOOF_DEVICE_ID.startsWith(DEVICE_ID_PLACEHOLDER_PREFIX)) {
            hookAppDeviceId(cl);
        }

        // 1) Keep native freeRASP/AppiCrypt initialization enabled by default.
        //    The old no-op is retained behind an explicit diagnostic switch so
        //    this remains a one-variable, reversible A/B test.
        if (BYPASS_RASP_START) {
            try {
                XposedHelpers.findAndHookMethod(PLUGIN, cl, "registerListeners",
                    "com.facebook.react.bridge.Promise", new XC_MethodHook() {
                        protected void beforeHookedMethod(MethodHookParam p) {
                            try {
                                if (p.args.length > 0 && p.args[0] != null)
                                    XposedHelpers.callMethod(p.args[0], "resolve", "Talsec Listeners Registered");
                            } catch (Throwable t) {}
                            p.setResult(null);
                            XposedBridge.log(TAG + "registerListeners -> NO-OP (diagnostic mode)");
                        }
                    });
            } catch (Throwable t) { XposedBridge.log(TAG + "registerListeners hook FAILED: " + t); }
        } else {
            XposedBridge.log(TAG + "registerListeners left active (native RASP starts normally)");
        }

        // 2) no-op onInvalidCallback (its body is Process.killProcess)
        try {
            XposedHelpers.findAndHookMethod(PLUGIN, cl, "onInvalidCallback", new XC_MethodHook() {
                protected void beforeHookedMethod(MethodHookParam p) {
                    p.setResult(null);
                    XposedBridge.log(TAG + "onInvalidCallback -> NO-OP");
                }
            });
        } catch (Throwable t) { XposedBridge.log(TAG + "onInvalidCallback hook note: " + t); }

        // 3) BELT: block process termination
        try {
            XposedHelpers.findAndHookMethod("java.lang.System", cl, "exit", int.class, new XC_MethodHook() {
                protected void beforeHookedMethod(MethodHookParam p) { p.setResult(null); XposedBridge.log(TAG + "System.exit blocked"); }
            });
        } catch (Throwable t) {}
        // Process.killProcess() is only the Java wrapper. Android also exposes
        // killProcessQuiet() and the native sendSignal*() entry points. A native
        // caller can reach those directly, which shows up as libc kill() called
        // from ART's generic JNI trampoline and bypasses a killProcess-only hook.
        hookSelfSigkill(cl, "killProcess", false);
        hookSelfSigkill(cl, "killProcessQuiet", false);
        hookSelfSigkill(cl, "sendSignal", true);
        hookSelfSigkill(cl, "sendSignalQuiet", true);

        // The hardened SDK's delayed termination path is Java -> JNI:
        // C10611o0 posts an eight-second task which invokes FNatives.x(int),
        // and that one native method calls getpid(); kill(pid, SIGKILL).
        // Hook only x(), leaving FNatives.y()/z() (app crypto/integrity) intact.
        try {
            XposedHelpers.findAndHookMethod("androidx.security.FNatives", cl, "x",
                int.class, new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        p.setResult(null);
                        XposedBridge.log(TAG + "FNatives.x native self-kill blocked");
                    }
                });
            XposedBridge.log(TAG + "FNatives.x native self-kill guard installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "FNatives.x hook FAILED: " + t);
        }

        // 4) BELT: blank TALSEC_INFO broadcast extras (string + serializable)
        try {
            XposedHelpers.findAndHookMethod("android.content.Intent", cl, "getStringExtra", String.class, new XC_MethodHook() {
                protected void afterHookedMethod(MethodHookParam p) {
                    try { if ("TALSEC_INFO".equals(XposedHelpers.callMethod(p.thisObject, "getAction"))) p.setResult(""); } catch (Throwable t) {}
                }
            });
        } catch (Throwable t) {}
        try {
            XposedHelpers.findAndHookMethod("android.content.Intent", cl, "getSerializableExtra", String.class, new XC_MethodHook() {
                protected void afterHookedMethod(MethodHookParam p) {
                    try { if ("TALSEC_INFO".equals(XposedHelpers.callMethod(p.thisObject, "getAction"))) p.setResult(null); } catch (Throwable t) {}
                }
            });
        } catch (Throwable t) {}

        // 5) Keep the UI alive: block every teardown path the threat reaction can use
        //    (Activity.finish*, ActivityManager.AppTask.finishAndRemoveTask = closeAllTasks
        //    pattern, moveTaskToBack) so the app can't be backgrounded -> cached -> reaped.
        for (String m : new String[]{"finishAndRemoveTask", "finishAffinity", "finish"}) {
            try {
                XposedHelpers.findAndHookMethod("android.app.Activity", cl, m, new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) { p.setResult(null); XposedBridge.log(TAG + "Activity." + m + " blocked"); }
                });
            } catch (Throwable t) {}
        }
        try {
            XposedHelpers.findAndHookMethod("android.app.ActivityManager$AppTask", cl, "finishAndRemoveTask", new XC_MethodHook() {
                protected void beforeHookedMethod(MethodHookParam p) { p.setResult(null); XposedBridge.log(TAG + "AppTask.finishAndRemoveTask blocked"); }
            });
        } catch (Throwable t) {}
        try {
            XposedHelpers.findAndHookMethod("android.app.Activity", cl, "moveTaskToBack", boolean.class, new XC_MethodHook() {
                protected void beforeHookedMethod(MethodHookParam p) { p.setResult(false); XposedBridge.log(TAG + "moveTaskToBack blocked"); }
            });
        } catch (Throwable t) {}
        // 6) STABILITY: desync the JS threat channel so the reaction never reaches JS.
        //    Talsec delivers threats over a NativeEventEmitter channel whose names are
        //    per-session SecureRandom ints (Nd.AbstractC3346p.f15645b/c/d). JS calls
        //    getThreatChannelData() to learn them, subscribes, and native emits on those
        //    same names. Return DEAD names to JS -> JS listens on channels native never
        //    emits on -> no "Device Insecure" screen -> app not backgrounded/reaped.
        try {
            XposedHelpers.findAndHookMethod(PLUGIN, cl, "getThreatChannelData",
                "com.facebook.react.bridge.Promise", new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        try {
                            Class<?> args = XposedHelpers.findClass("com.facebook.react.bridge.Arguments", cl);
                            Object arr = XposedHelpers.callStaticMethod(args, "createArray");
                            XposedHelpers.callMethod(arr, "pushString", "dead_ch_a");
                            XposedHelpers.callMethod(arr, "pushString", "dead_ch_b");
                            XposedHelpers.callMethod(arr, "pushString", "dead_ch_c");
                            XposedHelpers.callMethod(p.args[0], "resolve", arr);
                            p.setResult(null);
                            XposedBridge.log(TAG + "getThreatChannelData -> DESYNCED (JS on dead channels)");
                        } catch (Throwable t) { XposedBridge.log(TAG + "threat desync err: " + t); }
                    }
                });
        } catch (Throwable t) { XposedBridge.log(TAG + "getThreatChannelData hook FAILED: " + t); }

        XposedBridge.log(TAG + "reaction guards installed (native RASP active, threat channel desynced)");
    }

    private void hookSelfSigkill(final ClassLoader cl, final String method,
                                 final boolean explicitSignal) {
        try {
            XC_MethodHook guard = new XC_MethodHook() {
                protected void beforeHookedMethod(MethodHookParam p) {
                    if (p.args == null || p.args.length == 0 || !(p.args[0] instanceof Number)) return;

                    int targetPid = ((Number) p.args[0]).intValue();
                    int signal = explicitSignal && p.args.length > 1 && p.args[1] instanceof Number
                        ? ((Number) p.args[1]).intValue() : 9;
                    Object current = XposedHelpers.callStaticMethod(
                        XposedHelpers.findClass("android.os.Process", null), "myPid");
                    int currentPid = ((Number) current).intValue();

                    // Leave ordinary signals and calls targeting other processes alone.
                    if (targetPid == currentPid && signal == 9) {
                        p.setResult(null);
                        XposedBridge.log(TAG + "Process." + method + " self-SIGKILL blocked");
                    }
                }
            };

            if (explicitSignal) {
                XposedHelpers.findAndHookMethod("android.os.Process", cl, method,
                    int.class, int.class, guard);
            } else {
                XposedHelpers.findAndHookMethod("android.os.Process", cl, method,
                    int.class, guard);
            }
            XposedBridge.log(TAG + "Process." + method + " self-SIGKILL guard installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "Process." + method + " hook note: " + t);
        }
    }

    private void hookThreatCallback(final ClassLoader cl, final String className,
                                    final String method, final String threatName) {
        try {
            XposedHelpers.findAndHookMethod(className, cl, method, new XC_MethodHook() {
                protected void beforeHookedMethod(MethodHookParam p) {
                    XposedBridge.log(TAG + "native threat detected: " + threatName);
                }
            });
        } catch (Throwable t) {
            XposedBridge.log(TAG + "threat telemetry hook " + threatName + " note: " + t);
        }
    }

    private void hookAppiCryptInputs(final ClassLoader cl) {
        // JADX aliases this raw default-package class as defpackage.C11663t.
        // Its c(Long) result is the JSON configuration immediately before it is
        // obfuscated and supplied to FNatives.z() as dataToSign.
        try {
            XposedHelpers.findAndHookMethod("t", cl, "c", Long.class,
                new XC_MethodHook() {
                    protected void afterHookedMethod(MethodHookParam p) {
                        Object value = p.getResult();
                        XposedBridge.log(TAG + "AppiCrypt config JSON: "
                            + (value == null ? "null" : value.toString()));
                        if (SPOOF_APPICRYPT_CHECKS && value != null) {
                            try {
                                setCheckStatus(value, "unofficialStore", "OK");
                                setCheckStatus(value, "privilegedAccess", "OK");
                                XposedBridge.log(TAG + "AppiCrypt spoofed JSON: " + value.toString());
                            } catch (Throwable t) {
                                XposedBridge.log(TAG + "AppiCrypt JSON spoof FAILED: " + t);
                            }
                        }
                    }
                });
            XposedBridge.log(TAG + "AppiCrypt pre-signing config probe installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "AppiCrypt config probe FAILED: " + t);
        }

        try {
            Class<?> contextClass = XposedHelpers.findClass("android.content.Context", cl);
            XposedHelpers.findAndHookMethod("androidx.security.FNatives", cl, "z",
                contextClass, byte[].class, String.class, byte[].class,
                byte[].class, byte[].class, long.class, new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        byte[] publicKey = (byte[]) p.args[1];
                        byte[] nonce = (byte[]) p.args[3];
                        byte[] dataToSign = (byte[]) p.args[4];
                        byte[] apkDerived = (byte[]) p.args[5];
                        XposedBridge.log(TAG + "FNatives.z inputs: kid=" + p.args[2]
                            + " publicKeyLen=" + length(publicKey)
                            + " nonceLen=" + length(nonce)
                            + " dataToSignLen=" + length(dataToSign)
                            + " apkDerived=" + toHex(apkDerived)
                            + " configCrc32=" + p.args[6]);
                    }
                });
            XposedBridge.log(TAG + "FNatives.z metadata probe installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "FNatives.z metadata probe FAILED: " + t);
        }
    }

    private void hookInstallSource(final ClassLoader cl) {
        try {
            Class<?> pm = XposedHelpers.findClass("android.app.ApplicationPackageManager", cl);
            XposedHelpers.findAndHookMethod(pm, "getInstallerPackageName", String.class,
                new XC_MethodHook() {
                    protected void afterHookedMethod(MethodHookParam p) {
                        if (TARGET_PACKAGE.equals(p.args[0])) {
                            XposedBridge.log(TAG + "installerPackageName=" + p.getResult());
                        }
                    }
                });
            XposedHelpers.findAndHookMethod(pm, "getInstallSourceInfo", String.class,
                new XC_MethodHook() {
                    protected void afterHookedMethod(MethodHookParam p) {
                        if (!TARGET_PACKAGE.equals(p.args[0]) || p.getResult() == null) return;
                        Object info = p.getResult();
                        XposedBridge.log(TAG + "installSourceInfo: initiating="
                            + XposedHelpers.callMethod(info, "getInitiatingPackageName")
                            + " originating="
                            + XposedHelpers.callMethod(info, "getOriginatingPackageName")
                            + " installing="
                            + XposedHelpers.callMethod(info, "getInstallingPackageName"));
                    }
                });
            XposedBridge.log(TAG + "install-source value probe installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "install-source probe FAILED: " + t);
        }
    }

    private void hookAppDeviceId(final ClassLoader cl) {
        try {
            XposedHelpers.findAndHookMethod(
                "com.learnium.RNDeviceInfo.RNDeviceModule", cl, "getUniqueIdSync",
                new XC_MethodHook() {
                    protected void afterHookedMethod(MethodHookParam p) {
                        XposedBridge.log(TAG + "RNDeviceInfo unique ID overridden for accepted-session A/B");
                        p.setResult(SPOOF_DEVICE_ID);
                    }
                });
            XposedBridge.log(TAG + "accepted-session device-ID hook installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "device-ID hook FAILED: " + t);
        }
    }

    private static int length(byte[] value) {
        return value == null ? -1 : value.length;
    }

    private static void setCheckStatus(Object root, String checkName, String status) {
        Object checks = XposedHelpers.callMethod(root, "getJSONObject", "checks");
        Object check = XposedHelpers.callMethod(checks, "getJSONObject", checkName);
        XposedHelpers.callMethod(check, "put", "status", status);
    }

    private static String toHex(byte[] value) {
        if (value == null) return "null";
        StringBuilder out = new StringBuilder(value.length * 2);
        for (byte b : value) out.append(String.format("%02x", b & 0xff));
        return out.toString();
    }
}
