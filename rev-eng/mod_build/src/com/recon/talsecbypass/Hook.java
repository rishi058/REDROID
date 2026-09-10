package com.recon.talsecbypass;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

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

    // ── core behaviour toggles ───────────────────────────────────────────────
    private static final boolean PASSIVE_INTEGRITY_TEST  = false;
    private static final boolean BYPASS_RASP_START       = false;

    // ── existing logging / spoofing ──────────────────────────────────────────
    private static final boolean LOG_NATIVE_THREATS      = true;
    private static final boolean LOG_APPICRYPT_INPUTS    = true;
    private static final boolean LOG_INSTALL_SOURCE      = true;
    private static final boolean SPOOF_APPICRYPT_CHECKS  = true;

    // ── NEW: blanket mutation ────────────────────────────────────────────────
    // Iterate ALL checks in the AppiCrypt JSON and set every NOK entry to OK,
    // not just the two that were previously hard-coded.  This is a superset of
    // the prior behaviour and is safe to leave enabled.
    private static final boolean SPOOF_ALL_NOK_CHECKS    = true;

    // ── NEW: extended diagnostics ────────────────────────────────────────────
    // Log the complete checks sub-tree (all key→status pairs) before mutation.
    private static final boolean LOG_FULL_CHECKS_JSON    = true;
    // Log the four device-identifier values returned by getIdentifiers().
    // Only presence/length is emitted — no actual identifier bytes.
    private static final boolean LOG_IDENTIFIERS         = true;
    // Desync the RASP-execution-state channel in addition to the threat channel.
    private static final boolean DESYNC_RASP_STATE_CHANNEL = true;
    // Log the nonce length and cloud-project number for every Play Integrity
    // requestToken call (no nonce value, no token).
    private static final boolean LOG_PLAY_INTEGRITY      = true;
    // Log getCryptogram() entry / outcome (no cryptogram value).
    private static final boolean LOG_CRYPTOGRAM_RESULT   = true;
    // Log FNatives.y (the second native protected operation) call/return size.
    private static final boolean LOG_FNATIVES_Y          = true;
    // Log FNatives.z return-value size and the set of threats that fired before
    // it was invoked (key diagnostic: which RASP signals are in the cryptogram).
    private static final boolean LOG_FNATIVES_Z_RETURN   = true;
    // RevenueCat's default getCustomerInfo() path can wait indefinitely for a
    // broken Play Billing connection before returning data that is already in
    // its persisted native cache. Resolve the React Native promise from that
    // real cache when available; never fabricate an entitlement or customer.
    private static final boolean USE_CACHED_REVENUECAT_CUSTOMER_INFO = true;

    // ── AppLovin MAX resource containment ────────────────────────────────────
    // Diskwala's global AdProvider reloads the same full-screen ad units after
    // hide/failure with no backoff. Every reload fans into the installed MAX
    // mediation adapters, which have been observed creating hundreds of
    // long-lived executor threads in one app process. Keep the first load and
    // permit a periodic refresh, but suppress hot-loop reloads at the narrow RN
    // bridge boundary. Endpoint reachability/ad-block checks remain untouched.
    private static final boolean LIMIT_APPLOVIN_RELOADS = true;
    private static final boolean DISABLE_APPLOVIN_AUTO_REFRESH = true;
    private static final long APPLOVIN_LOAD_COOLDOWN_MS = 10L * 60L * 1000L;
    private static final int APPLOVIN_TRACKED_UNIT_LIMIT = 64;

    // Exact root-cause fix: Talsec's R2.P creates a fresh four-core scheduler on
    // every React host resume, stores only its Future, and never shuts the pool
    // down. Reuse one scheduler while preserving R2's schedule/cancel behavior.
    private static final boolean REUSE_TALSEC_ACCESSIBILITY_SCHEDULER = true;
    // Broad constructor telemetry was needed only to identify R2.P. Keep the
    // implementation available for diagnostics but disable it in the final fix.
    private static final boolean EXECUTOR_ATTRIBUTION_ENABLED = false;

    // ── ad-SDK scheduled-pool thread-leak containment (v1.4) ──────────────────
    // ROOT-CAUSE FIX. Ad loaders each create a ScheduledThreadPoolExecutor via
    // Executors.newScheduledThreadPool(2..4), submit one-shot work, and NEVER
    // call shutdown(), so 2-4 CORE workers park forever in
    // ScheduledThreadPoolExecutor$DelayedWorkQueue.take(). Hundreds of ad loads
    // => thousands of dead threads and ~1 GiB RSS, which saturates the
    // single-core Redroid and hangs the device (TALSEC_v1.3.md §3, §10). The fix
    // lets IDLE CORE workers of ad-owned pools retire and be recreated on
    // demand: allowCoreThreadTimeOut(true) + a keep-alive. Task semantics are
    // unchanged — only workers that have sat idle with an empty queue retire.
    //
    // SAFETY: allowCoreThreadTimeOut on a ScheduledThreadPoolExecutor can orphan
    // a queued task only if that task's delay/period exceeds the keep-alive AND
    // every worker times out first. Decompiled ground truth: io.bidmachine (the
    // dominant, confirmed owner) does ZERO periodic scheduling and only submits
    // immediate/short work, so it can never be orphaned. For any other owner we
    // broaden to, the periodic auto-backoff guards below disable the timeout on
    // any pool that ever receives a periodic task, so broadening stays safe.
    // v1.4.1 is attribution-only. Do not mutate any SDK executor until its
    // concrete pool-N prefix and constructor owner are proven under live load.
    private static final boolean CONTAIN_SCHEDULED_POOL_LEAK = false;
    // Owner package prefixes whose scheduled pools get the idle-core timeout.
    // Default: only io.bidmachine (proven one-shot + the dominant leaker). The
    // monitoring below prints every other owner and its pool count so the list
    // can be widened from evidence; the periodic auto-backoff keeps that safe.
    private static final String[] SCHEDULED_POOL_TRIM_OWNER_PREFIXES = {};
    // Idle keep-alive for a trimmed pool's core workers. 60s comfortably retires
    // the leaked one-shot pools while keeping a warm worker for any short
    // periodic task (period < keep-alive re-runs before the worker retires).
    private static final long SCHEDULED_POOL_IDLE_TIMEOUT_SECONDS = 60L;
    // Throttle for the process thread-count / pool summary emitted to logcat.
    private static final long POOL_MONITOR_INTERVAL_MS = 60L * 1000L;
    private static final int MAX_EXECUTOR_CREATE_LOGS = 2000;

    // ── mutable state ────────────────────────────────────────────────────────
    private static boolean loggedAppiCryptCheckSchema = false;
    // Accumulates every native threat name that fires after process start.
    // Emitted alongside the FNatives.z return so we can correlate what the
    // native signer "saw" with whether the server accepted the cryptogram.
    private static final Set<String> firedThreats = new LinkedHashSet<>();
    private static final Object firedThreatsLock = new Object();
    private static final Object appLovinLoadLock = new Object();
    private static final Map<String, Long> appLovinLastAllowedLoad = new LinkedHashMap<>();
    private static final Map<String, Integer> appLovinSuppressedLoads = new LinkedHashMap<>();
    private static boolean loggedAutoRefreshBlock = false;
    private static final Object talsecSchedulerLock = new Object();
    private static ScheduledThreadPoolExecutor talsecAccessibilityScheduler = null;
    private static int talsecSchedulerReuses = 0;
    private static final AtomicInteger talsecSchedulerThreadNumber = new AtomicInteger(1);
    private static final Object scheduledPoolLock = new Object();
    private static int scheduledPoolsSeen = 0;
    private static int ordinaryPoolsSeen = 0;
    private static int executorCreateLogs = 0;
    private static int scheduledFactoryProbeHits = 0;
    private static int scheduledFactoryLogs = 0;
    private static int scheduledPoolsTrimmed = 0;
    private static int scheduledPoolsBackedOff = 0;
    private static long lastPoolMonitorMs = 0L;
    // Pools we applied the idle-core timeout to (identity keys, weakly held so a
    // reclaimed pool does not pin memory).
    private static final Set<ScheduledThreadPoolExecutor> trimmedPools =
        Collections.newSetFromMap(new WeakHashMap<ScheduledThreadPoolExecutor, Boolean>());
    // Pools reverted because they received a periodic task — never re-trim these.
    private static final Set<ScheduledThreadPoolExecutor> periodicPools =
        Collections.newSetFromMap(new WeakHashMap<ScheduledThreadPoolExecutor, Boolean>());
    // Weak identity registry. WeakHashMap uses equals/hashCode and can merge
    // executor subclasses that override them; this list dedupes strictly by ==.
    private static final ArrayList<WeakReference<ThreadPoolExecutor>> observedExecutorPools =
        new ArrayList<>();
    private static final Map<String, Integer> scheduledPoolOwnerCounts = new LinkedHashMap<>();
    private static final Map<String, Integer> ordinaryPoolOwnerCounts = new LinkedHashMap<>();

    // ────────────────────────────────────────────────────────────────────────
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lp) throws Throwable {
        if (!TARGET_PACKAGE.equals(lp.packageName)) return;
        final ClassLoader cl = lp.classLoader;
        XposedBridge.log(TAG + "loaded in " + lp.packageName);

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
        if (LOG_IDENTIFIERS) {
            hookGetIdentifiers(cl);
        }
        if (DESYNC_RASP_STATE_CHANNEL) {
            hookRaspExecutionState(cl);
        }
        if (LOG_PLAY_INTEGRITY) {
            hookPlayIntegrityRequest(cl);
        }
        if (LOG_CRYPTOGRAM_RESULT) {
            hookCryptogramResult(cl);
        }
        if (USE_CACHED_REVENUECAT_CUSTOMER_INFO) {
            hookCachedRevenueCatCustomerInfo(cl);
        }
        hookAppLovinResourceGuards(cl);
        if (REUSE_TALSEC_ACCESSIBILITY_SCHEDULER) {
            hookTalsecAccessibilitySchedulerReuse();
        }
        if (EXECUTOR_ATTRIBUTION_ENABLED) {
            hookScheduledPoolContainment(cl);
        } else {
            XposedBridge.log(TAG + "broad executor attribution disabled in final fix");
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

    // ── AppLovin MAX resource containment ───────────────────────────────────
    private void hookAppLovinResourceGuards(final ClassLoader cl) {
        if (LIMIT_APPLOVIN_RELOADS) {
            hookAppLovinLoadMethod(cl, "loadInterstitial", "interstitial");
            hookAppLovinLoadMethod(cl, "loadRewardedAd", "rewarded");
        }

        if (DISABLE_APPLOVIN_AUTO_REFRESH) {
            try {
                XposedHelpers.findAndHookMethod(
                    "com.applovin.reactnative.AppLovinMAXAdView", cl,
                    "setAutoRefreshEnabled", boolean.class,
                    new XC_MethodHook() {
                        protected void beforeHookedMethod(MethodHookParam p) {
                            if (!Boolean.TRUE.equals(p.args[0])) return;
                            p.args[0] = false;
                            synchronized (appLovinLoadLock) {
                                if (!loggedAutoRefreshBlock) {
                                    loggedAutoRefreshBlock = true;
                                    XposedBridge.log(TAG
                                        + "AppLovin banner/MREC auto-refresh disabled; initial load preserved");
                                }
                            }
                        }
                    });
                XposedBridge.log(TAG + "AppLovin auto-refresh guard installed");
            } catch (Throwable t) {
                XposedBridge.log(TAG + "AppLovin auto-refresh hook note: " + t);
            }
        }
    }

    private void hookAppLovinLoadMethod(final ClassLoader cl, final String method,
                                        final String format) {
        try {
            XposedHelpers.findAndHookMethod(
                "com.applovin.reactnative.AppLovinMAXModuleImpl", cl,
                method, String.class, new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        String adUnitId = p.args[0] instanceof String
                            ? (String) p.args[0] : null;
                        if (adUnitId == null || adUnitId.isEmpty()) return;

                        String key = format + ":" + adUnitId;
                        long now = System.nanoTime() / 1_000_000L;
                        long remaining;
                        int suppressed;
                        synchronized (appLovinLoadLock) {
                            pruneAppLovinLoadState(now);
                            Long last = appLovinLastAllowedLoad.get(key);
                            if (last == null || now - last.longValue() >= APPLOVIN_LOAD_COOLDOWN_MS) {
                                appLovinLastAllowedLoad.put(key, Long.valueOf(now));
                                appLovinSuppressedLoads.put(key, Integer.valueOf(0));
                                XposedBridge.log(TAG + "AppLovin " + format
                                    + " load allowed unit=" + unitFingerprint(adUnitId));
                                return;
                            }

                            remaining = APPLOVIN_LOAD_COOLDOWN_MS - (now - last.longValue());
                            suppressed = appLovinSuppressedLoads.containsKey(key)
                                ? appLovinSuppressedLoads.get(key).intValue() + 1 : 1;
                            appLovinSuppressedLoads.put(key, Integer.valueOf(suppressed));
                        }

                        // The native bridge method is void. Returning null drops
                        // only this duplicate load request; readiness/event APIs,
                        // SDK initialization, and Diskwala networking remain real.
                        p.setResult(null);
                        if (suppressed == 1 || suppressed % 25 == 0) {
                            XposedBridge.log(TAG + "AppLovin " + format
                                + " reload suppressed unit=" + unitFingerprint(adUnitId)
                                + " count=" + suppressed
                                + " retryInSec=" + ((remaining + 999L) / 1000L));
                        }
                    }
                });
            XposedBridge.log(TAG + "AppLovin " + method + " limiter installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "AppLovin " + method + " hook FAILED: " + t);
        }
    }

    // The app currently has only a handful of static MAX units, but keep this
    // module-owned cache bounded if a future app version supplies dynamic IDs.
    private static void pruneAppLovinLoadState(long now) {
        Iterator<Map.Entry<String, Long>> iterator =
            appLovinLastAllowedLoad.entrySet().iterator();
        while (iterator.hasNext()) {
            Map.Entry<String, Long> entry = iterator.next();
            if (now - entry.getValue().longValue() >= APPLOVIN_LOAD_COOLDOWN_MS) {
                appLovinSuppressedLoads.remove(entry.getKey());
                iterator.remove();
            }
        }
        while (appLovinLastAllowedLoad.size() >= APPLOVIN_TRACKED_UNIT_LIMIT) {
            Iterator<String> keys = appLovinLastAllowedLoad.keySet().iterator();
            if (!keys.hasNext()) break;
            String eldest = keys.next();
            keys.remove();
            appLovinSuppressedLoads.remove(eldest);
        }
    }

    private void hookTalsecAccessibilitySchedulerReuse() {
        try {
            XposedHelpers.findAndHookMethod(
                Executors.class, "newScheduledThreadPool", int.class,
                new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        try {
                            int requestedCore = ((Number) p.args[0]).intValue();
                            if (requestedCore != 4 || !calledFromTalsecR2P()) return;

                            ScheduledThreadPoolExecutor scheduler;
                            int reuseCount;
                            synchronized (talsecSchedulerLock) {
                                scheduler = talsecAccessibilityScheduler;
                                if (scheduler == null || scheduler.isShutdown()
                                        || scheduler.isTerminated()) {
                                    final ThreadFactory delegate =
                                        Executors.defaultThreadFactory();
                                    scheduler = new ScheduledThreadPoolExecutor(
                                        requestedCore, new ThreadFactory() {
                                            public Thread newThread(Runnable task) {
                                                Thread thread = delegate.newThread(task);
                                                thread.setName("TalsecA11yMonitor-"
                                                    + talsecSchedulerThreadNumber.getAndIncrement());
                                                return thread;
                                            }
                                        });
                                    scheduler.setRemoveOnCancelPolicy(true);
                                    talsecAccessibilityScheduler = scheduler;
                                    talsecSchedulerReuses = 0;
                                    XposedBridge.log(TAG
                                        + "Talsec R2.P shared scheduler created core="
                                        + requestedCore);
                                }
                                reuseCount = ++talsecSchedulerReuses;
                            }

                            p.setResult(scheduler);
                            if (reuseCount <= 5 || reuseCount % 50 == 0) {
                                XposedBridge.log(TAG
                                    + "Talsec R2.P scheduler reused count=" + reuseCount
                                    + " id=" + Integer.toHexString(
                                        System.identityHashCode(scheduler)));
                            }
                        } catch (Throwable t) {
                            // Fail open: if the guard cannot prove/reuse the
                            // scheduler, run the app's original factory call.
                            XposedBridge.log(TAG
                                + "Talsec R2.P scheduler reuse note: " + t);
                        }
                    }
                });
            XposedBridge.log(TAG + "Talsec R2.P scheduler reuse hook installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG
                + "Talsec R2.P scheduler reuse hook FAILED: " + t);
        }
    }

    private static boolean calledFromTalsecR2P() {
        boolean sawR2P = false;
        boolean sawH4ResumeRegistration = false;
        boolean sawTalsecHostResume = false;
        for (StackTraceElement frame : Thread.currentThread().getStackTrace()) {
            String className = frame.getClassName();
            String methodName = frame.getMethodName();
            // Runtime telemetry from this exact APK reports raw DEX names R2,
            // h4.g and wd.M (JADX's "defpackage" is only a source alias).
            if ("R2".equals(className) && "P".equals(methodName)) sawR2P = true;
            if ("h4.g".equals(className) && "b".equals(methodName)) {
                sawH4ResumeRegistration = true;
            }
            if ("wd.M".equals(className) && "onHostResume".equals(methodName)) {
                sawTalsecHostResume = true;
            }
        }
        return sawR2P && sawH4ResumeRegistration && sawTalsecHostResume;
    }

    // ART dumps showed hundreds of default-named workers owned by BidMachine's
    // GAMTaskLoader. Every loader creates a 2–4 core scheduled executor, submits
    // only immediate work, and never shuts it down. Keep all executor/task
    // semantics, but allow idle core workers to retire and be recreated later.
    private void hookScheduledPoolContainment(final ClassLoader cl) {
        // 1) Observe ordinary pools as well. v1.4 covered only STPE while live
        //    pool-N workers grew by hundreds; fixed/cached/single executors use
        //    the ThreadPoolExecutor base class instead.
        try {
            XposedBridge.hookAllConstructors(
                ThreadPoolExecutor.class, new XC_MethodHook() {
                    protected void afterHookedMethod(MethodHookParam p) {
                        try {
                            if (!(p.thisObject instanceof ThreadPoolExecutor)) return;
                            if (p.thisObject instanceof ScheduledThreadPoolExecutor) return;
                            ThreadPoolExecutor pool = (ThreadPoolExecutor) p.thisObject;
                            String owner = scheduledExecutorOwner();
                            recordExecutorPool("TPE", pool, owner, "constructor");
                            maybeLogPoolMonitor();
                        } catch (Throwable t) {
                            XposedBridge.log(TAG + "ordinary-pool afterCtor note: " + t);
                        }
                    }
                });
            XposedBridge.log(TAG + "ordinary-pool constructor probe installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "ordinary-pool constructor hook FAILED: " + t);
        }

        // 2) Every scheduled pool the app or an ad SDK creates goes through a
        //    `new ScheduledThreadPoolExecutor(...)` (both
        //    Executors.newScheduledThreadPool and newSingleThreadScheduledExecutor
        //    construct one). Intercepting the constructor catches ALL of them
        //    regardless of which SDK, so we can attribute the owner from the live
        //    construction stack and retire idle CORE workers only for ad-owned
        //    pools. This is the interception point the v1.3 probe already proved
        //    fires; the fix here is correct owner attribution + applying the
        //    timeout by owner package instead of one hard-coded class.
        try {
            XposedBridge.hookAllConstructors(
                ScheduledThreadPoolExecutor.class, new XC_MethodHook() {
                    protected void afterHookedMethod(MethodHookParam p) {
                        try {
                            if (!(p.thisObject instanceof ScheduledThreadPoolExecutor)) return;
                            ScheduledThreadPoolExecutor pool =
                                (ScheduledThreadPoolExecutor) p.thisObject;
                            String owner = scheduledExecutorOwner();
                            recordExecutorPool("STPE", pool, owner, "constructor");
                            if (CONTAIN_SCHEDULED_POOL_LEAK && ownerIsTrimTarget(owner)) {
                                trimScheduledPool(pool, owner);
                            }
                            maybeLogPoolMonitor();
                        } catch (Throwable t) {
                            XposedBridge.log(TAG + "scheduled-pool afterCtor note: " + t);
                        }
                    }
                });
            XposedBridge.log(TAG + "scheduled-pool constructor probe installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "scheduled-pool constructor hook FAILED: " + t);
        }

        installScheduledFactoryProbe("newScheduledThreadPool", int.class);
        installScheduledFactoryProbe(
            "newScheduledThreadPool", int.class, ThreadFactory.class);
        installScheduledFactoryProbe("newSingleThreadScheduledExecutor");
        installScheduledFactoryProbe(
            "newSingleThreadScheduledExecutor", ThreadFactory.class);

        runExecutorTelemetryCanary();

        if (!CONTAIN_SCHEDULED_POOL_LEAK) {
            XposedBridge.log(TAG + "executor attribution mode: all pool mutation disabled");
            return;
        }

        // 3) SAFETY NET. allowCoreThreadTimeOut can orphan a queued task only if
        //    its delay/period exceeds the keep-alive AND every worker retires
        //    first. A pool that ever schedules PERIODIC work must therefore keep
        //    a live worker: revert the timeout on it and never trim it again.
        //    This is what makes widening SCHEDULED_POOL_TRIM_OWNER_PREFIXES safe
        //    — a periodic task can never be starved by our change. (The default
        //    allowlist, io.bidmachine, schedules no periodic work at all, so it
        //    is safe even without this net; the net exists for broadening.)
        installPeriodicBackoffGuard("scheduleAtFixedRate");
        installPeriodicBackoffGuard("scheduleWithFixedDelay");
    }

    private void installScheduledFactoryProbe(
            final String method, Class<?>... parameterTypes) {
        try {
            Object[] signature = new Object[parameterTypes.length + 1];
            for (int i = 0; i < parameterTypes.length; i++) {
                signature[i] = parameterTypes[i];
            }
            signature[parameterTypes.length] = new XC_MethodHook() {
                protected void afterHookedMethod(MethodHookParam p) {
                    try {
                        ScheduledThreadPoolExecutor pool =
                            unwrapScheduledExecutor(p.getResult());
                        if (pool == null) {
                            XposedBridge.log(TAG + "POOL FACTORY unwrap FAILED method="
                                + method + " result="
                                + (p.getResult() == null ? "null"
                                   : p.getResult().getClass().getName()));
                            return;
                        }
                        String owner = scheduledExecutorOwner();
                        ThreadFactory factory = pool.getThreadFactory();
                        int factoryHit;
                        boolean logFactory;
                        synchronized (scheduledPoolLock) {
                            factoryHit = ++scheduledFactoryProbeHits;
                            logFactory = scheduledFactoryLogs < MAX_EXECUTOR_CREATE_LOGS;
                            if (logFactory) scheduledFactoryLogs++;
                        }
                        if (logFactory) {
                            XposedBridge.log(TAG + "POOL FACTORY"
                                + " method=Executors." + method
                                + " hit=" + factoryHit
                                + " id=" + Integer.toHexString(System.identityHashCode(pool))
                                + " prefix=" + threadFactoryPrefix(factory)
                                + " owner=" + owner
                                + " wrapper=" + (p.getResult() == null ? "null"
                                   : p.getResult().getClass().getName()));
                        }
                        recordExecutorPool(
                            "STPE", pool, owner, "Executors." + method);
                        maybeLogPoolMonitor();
                    } catch (Throwable t) {
                        XposedBridge.log(TAG + "POOL FACTORY note method="
                            + method + " err=" + t);
                    }
                }
            };
            XposedHelpers.findAndHookMethod(
                Executors.class, method, signature);
            XposedBridge.log(TAG + "POOL FACTORY probe installed method=" + method
                + " args=" + parameterTypes.length);
        } catch (Throwable t) {
            XposedBridge.log(TAG + "POOL FACTORY hook FAILED method=" + method
                + " args=" + parameterTypes.length + " err=" + t);
        }
    }

    private static ScheduledThreadPoolExecutor unwrapScheduledExecutor(Object value) {
        Object current = value;
        for (int depth = 0; depth < 4 && current != null; depth++) {
            if (current instanceof ScheduledThreadPoolExecutor) {
                return (ScheduledThreadPoolExecutor) current;
            }
            try {
                Object nested = XposedHelpers.getObjectField(current, "e");
                if (nested == current) break;
                current = nested;
            } catch (Throwable ignored) {
                return null;
            }
        }
        return null;
    }

    private static void runExecutorTelemetryCanary() {
        int ordinaryBefore;
        int scheduledBefore;
        int factoryBefore;
        synchronized (scheduledPoolLock) {
            ordinaryBefore = ordinaryPoolsSeen;
            scheduledBefore = scheduledPoolsSeen;
            factoryBefore = scheduledFactoryProbeHits;
        }
        java.util.ArrayList<ExecutorService> pools = new java.util.ArrayList<>();
        try {
            pools.add(new ThreadPoolExecutor(
                1, 1, 1L, TimeUnit.SECONDS, new LinkedBlockingQueue<Runnable>()));
            pools.add(Executors.newFixedThreadPool(1));
            pools.add(Executors.newCachedThreadPool());
            pools.add(Executors.newSingleThreadExecutor());
            pools.add(new ScheduledThreadPoolExecutor(1));
            pools.add(Executors.newScheduledThreadPool(1));
            pools.add(Executors.newSingleThreadScheduledExecutor());
            ThreadFactory canaryFactory = Executors.defaultThreadFactory();
            pools.add(Executors.newScheduledThreadPool(1, canaryFactory));
            pools.add(Executors.newSingleThreadScheduledExecutor(canaryFactory));
            for (ExecutorService pool : pools) {
                pool.submit(new Runnable() {
                    public void run() {}
                }).get(2L, TimeUnit.SECONDS);
            }
        } catch (Throwable t) {
            XposedBridge.log(TAG + "POOL CANARY construction FAILED: " + t);
        } finally {
            for (ExecutorService pool : pools) {
                try { pool.shutdownNow(); } catch (Throwable ignored) {}
            }
        }
        int ordinaryDelta;
        int scheduledDelta;
        int factoryDelta;
        synchronized (scheduledPoolLock) {
            ordinaryDelta = ordinaryPoolsSeen - ordinaryBefore;
            scheduledDelta = scheduledPoolsSeen - scheduledBefore;
            factoryDelta = scheduledFactoryProbeHits - factoryBefore;
        }
        XposedBridge.log(TAG + "POOL CANARY ordinaryDelta=" + ordinaryDelta
            + " expected=4 scheduledDelta=" + scheduledDelta + " expected=5"
            + " factoryDelta=" + factoryDelta + " expected=4"
            + ((ordinaryDelta == 4 && scheduledDelta == 5 && factoryDelta == 4)
               ? " PASS" : " FAIL"));
    }

    private void installPeriodicBackoffGuard(final String method) {
        try {
            XposedBridge.hookAllMethods(
                ScheduledThreadPoolExecutor.class, method, new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        try {
                            if (p.thisObject instanceof ScheduledThreadPoolExecutor) {
                                backOffPeriodicPool(
                                    (ScheduledThreadPoolExecutor) p.thisObject);
                            }
                        } catch (Throwable t) { /* must never break scheduling */ }
                    }
                });
            XposedBridge.log(TAG + "periodic-backoff guard installed for " + method);
        } catch (Throwable t) {
            XposedBridge.log(TAG + "periodic-backoff guard " + method + " note: " + t);
        }
    }

    private static boolean ownerIsTrimTarget(String owner) {
        if (owner == null) return false;
        for (String prefix : SCHEDULED_POOL_TRIM_OWNER_PREFIXES) {
            if (owner.startsWith(prefix)) return true;
        }
        return false;
    }

    // Let idle CORE workers of an ad-owned pool retire. Task semantics are
    // unchanged: only workers sitting idle with an empty queue for the keep-alive
    // retire, and ScheduledThreadPoolExecutor recreates one on the next submit.
    private static void trimScheduledPool(ScheduledThreadPoolExecutor pool, String owner) {
        // corePoolSize == 0 + allowCoreThreadTimeOut is the ONE genuinely unsafe
        // combination (OpenJDK JDK-7091003 / JDK-8022642: a queued task can be
        // orphaned or hot-spin). It is also pointless — a zero-core pool has no
        // core workers to reclaim. Skip it. With corePoolSize >= 1 the OpenJDK/
        // AOSP getTask/ensurePrestart/processWorkerExit guards keep at least one
        // worker whenever the queue is non-empty, so even periodic tasks are not
        // orphaned; that is why widening the owner allowlist is safe.
        if (pool.getCorePoolSize() < 1) return;
        synchronized (scheduledPoolLock) {
            if (periodicPools.contains(pool)) return;   // known periodic — leave it alone
            if (trimmedPools.contains(pool)) return;    // already trimmed
            try {
                // Keep this mutation under the same lock as periodic backoff.
                // Otherwise a first periodic schedule could disable timeout and
                // race with this path re-enabling it after periodicPools is set.
                pool.setKeepAliveTime(
                    SCHEDULED_POOL_IDLE_TIMEOUT_SECONDS, TimeUnit.SECONDS);
                pool.allowCoreThreadTimeOut(true);
                pool.setRemoveOnCancelPolicy(true);
                trimmedPools.add(pool);
                int trimmed = ++scheduledPoolsTrimmed;
                if (trimmed <= 5 || trimmed % 50 == 0) {
                    XposedBridge.log(TAG
                        + "scheduled-pool idle-core timeout applied owner=" + owner
                        + " core=" + pool.getCorePoolSize()
                        + " timeoutSec=" + SCHEDULED_POOL_IDLE_TIMEOUT_SECONDS
                        + " trimmedPools=" + trimmed);
                }
            } catch (Throwable t) {
                // Best-effort rollback if a later setter failed after timeout
                // was enabled. Do not record a partially configured pool.
                try { pool.allowCoreThreadTimeOut(false); } catch (Throwable ignored) {}
                trimmedPools.remove(pool);
                XposedBridge.log(TAG
                    + "scheduled-pool trim note owner=" + owner + " err=" + t);
            }
        }
    }

    private static void backOffPeriodicPool(ScheduledThreadPoolExecutor pool) {
        synchronized (scheduledPoolLock) {
            if (!periodicPools.add(pool)) return;       // already handled
            boolean wasTrimmed = trimmedPools.remove(pool);
            int backedOff = ++scheduledPoolsBackedOff;
            if (wasTrimmed) {
                try {
                    pool.allowCoreThreadTimeOut(false); // keep a worker for periodic work
                } catch (Throwable t) { /* best effort */ }
                XposedBridge.log(TAG
                    + "scheduled-pool periodic task detected -> idle-core timeout"
                    + " REVERTED to protect periodic work backedOff=" + backedOff);
            }
        }
    }

    private static void recordExecutorPool(
            String type, ThreadPoolExecutor pool, String owner, String origin) {
        int observed;
        boolean logCreate;
        synchronized (scheduledPoolLock) {
            if (!markExecutorObserved(pool)) return;
            Map<String, Integer> counts;
            if ("STPE".equals(type)) {
                scheduledPoolsSeen++;
                counts = scheduledPoolOwnerCounts;
            } else {
                ordinaryPoolsSeen++;
                counts = ordinaryPoolOwnerCounts;
            }
            Integer prior = counts.get(owner);
            observed = prior == null ? 1 : prior.intValue() + 1;
            if (prior != null || counts.size() < 500) {
                counts.put(owner, Integer.valueOf(observed));
            }
            logCreate = executorCreateLogs < MAX_EXECUTOR_CREATE_LOGS;
            if (logCreate) executorCreateLogs++;
        }
        if (logCreate) {
            ThreadFactory factory = pool.getThreadFactory();
            String id = Integer.toHexString(System.identityHashCode(pool));
            String prefix = threadFactoryPrefix(factory);
            XposedBridge.log(TAG + "POOL CREATE"
                + " type=" + type
                + " id=" + id
                + " prefix=" + prefix
                + " owner=" + owner
                + " origin=" + origin
                + " class=" + pool.getClass().getName()
                + " core=" + pool.getCorePoolSize()
                + " max=" + pool.getMaximumPoolSize()
                + " keepAliveMs=" + pool.getKeepAliveTime(TimeUnit.MILLISECONDS)
                + " allowCoreTimeout=" + pool.allowsCoreThreadTimeOut()
                + " queue=" + pool.getQueue().getClass().getName()
                + " factory=" + (factory == null ? "null" : factory.getClass().getName())
                + " ownerCount=" + observed);
            XposedBridge.log(TAG + "POOL STACK"
                + " type=" + type
                + " id=" + id
                + " prefix=" + prefix
                + " owner=" + owner
                + " origin=" + origin
                + " frames=" + creatorStackSnapshot());
        }
    }

    // Caller holds scheduledPoolLock.
    private static boolean markExecutorObserved(ThreadPoolExecutor pool) {
        Iterator<WeakReference<ThreadPoolExecutor>> iterator =
            observedExecutorPools.iterator();
        while (iterator.hasNext()) {
            ThreadPoolExecutor observed = iterator.next().get();
            if (observed == null) {
                iterator.remove();
            } else if (observed == pool) {
                return false;
            }
        }
        observedExecutorPools.add(new WeakReference<ThreadPoolExecutor>(pool));
        return true;
    }

    private static String threadFactoryPrefix(ThreadFactory factory) {
        if (factory == null) return "null";
        try {
            Object value = XposedHelpers.getObjectField(factory, "namePrefix");
            if (value instanceof String) return (String) value;
        } catch (Throwable ignored) {}
        return "-";
    }

    private static String creatorStackSnapshot() {
        StringBuilder out = new StringBuilder();
        int kept = 0;
        for (StackTraceElement frame : Thread.currentThread().getStackTrace()) {
            if (isInfrastructureFrame(frame.getClassName())) continue;
            if (kept++ > 0) out.append('>');
            out.append(frame.getClassName()).append('#').append(frame.getMethodName())
                .append(':').append(frame.getLineNumber());
            if (kept >= 10) break;
        }
        return out.length() == 0 ? "unknown" : out.toString();
    }

    // Owner = the first application/SDK frame that created the pool, skipping the
    // JDK executor plumbing, the Android/ART runtime, and every Xposed/LSPosed
    // trampoline frame. The v1.3 probe stopped at "LSPHooker_#constructor"
    // because those synthetic frames were not skipped — that is fixed here.
    private static String scheduledExecutorOwner() {
        StackTraceElement[] stack = Thread.currentThread().getStackTrace();
        for (StackTraceElement frame : stack) {
            String name = frame.getClassName();
            if (isInfrastructureFrame(name)) continue;
            return name + "#" + frame.getMethodName();
        }
        return "unknown";
    }

    private static boolean isInfrastructureFrame(String name) {
        if (name == null) return true;
        return name.startsWith("java.")
            || name.startsWith("javax.")
            || name.startsWith("jdk.")
            || name.startsWith("sun.")
            || name.startsWith("dalvik.")
            || name.startsWith("libcore.")
            || name.startsWith("com.android.internal.")
            || name.startsWith("de.robv.")
            || name.startsWith("org.lsposed.")
            || name.startsWith("io.github.libxposed.")
            || name.startsWith("com.recon.talsecbypass.")
            || name.contains("LSPHooker")            // LSPosed method trampoline
            || name.contains("XposedBridge")
            || name.contains("XposedHelpers")
            || name.contains("XC_MethodHook");
    }

    // Process-wide thread-count + pool summary, piggybacked on pool creation and
    // throttled to POOL_MONITOR_INTERVAL_MS. This is the visible thread-surge
    // tracker in logcat: grep "POOL MONITOR" to watch threads plateau.
    private static void maybeLogPoolMonitor() {
        long now = System.currentTimeMillis();
        synchronized (scheduledPoolLock) {
            if (now - lastPoolMonitorMs < POOL_MONITOR_INTERVAL_MS) return;
            lastPoolMonitorMs = now;
            XposedBridge.log(TAG + "POOL MONITOR threads=" + currentThreadCount()
                + " ordinaryPoolsSeen=" + ordinaryPoolsSeen
                + " scheduledPoolsSeen=" + scheduledPoolsSeen
                + " trimmed=" + scheduledPoolsTrimmed
                + " periodicBackedOff=" + scheduledPoolsBackedOff
                + " topTpeOwners=[" + topOwnersSnapshot(ordinaryPoolOwnerCounts) + "]"
                + " topStpeOwners=[" + topOwnersSnapshot(scheduledPoolOwnerCounts) + "]");
        }
    }

    // Top three owners by pool-creation count. Caller must hold scheduledPoolLock.
    private static String topOwnersSnapshot(Map<String, Integer> ownerCounts) {
        String bestA = null;
        String bestB = null;
        String bestC = null;
        int ca = -1;
        int cb = -1;
        int cc = -1;
        for (Map.Entry<String, Integer> e : ownerCounts.entrySet()) {
            int c = e.getValue().intValue();
            String k = e.getKey();
            if (c > ca) {
                cc = cb; bestC = bestB; cb = ca; bestB = bestA; ca = c; bestA = k;
            } else if (c > cb) {
                cc = cb; bestC = bestB; cb = c; bestB = k;
            } else if (c > cc) {
                cc = c; bestC = k;
            }
        }
        StringBuilder sb = new StringBuilder();
        if (bestA != null) sb.append(shortOwner(bestA)).append("=").append(ca);
        if (bestB != null) sb.append(", ").append(shortOwner(bestB)).append("=").append(cb);
        if (bestC != null) sb.append(", ").append(shortOwner(bestC)).append("=").append(cc);
        return sb.length() == 0 ? "none" : sb.toString();
    }

    private static String shortOwner(String owner) {
        if (owner == null) return "null";
        int hash = owner.indexOf('#');
        return hash > 0 ? owner.substring(0, hash) : owner;
    }

    // Live thread count of THIS process from /proc/self/status (exact, cheap).
    // Falls back to the root ThreadGroup estimate if /proc is unreadable.
    private static int currentThreadCount() {
        java.io.BufferedReader r = null;
        try {
            r = new java.io.BufferedReader(new java.io.FileReader("/proc/self/status"));
            String line;
            while ((line = r.readLine()) != null) {
                if (line.startsWith("Threads:")) {
                    return Integer.parseInt(line.substring(8).trim());
                }
            }
        } catch (Throwable t) {
            // fall through to the ThreadGroup estimate
        } finally {
            if (r != null) { try { r.close(); } catch (Throwable ignored) {} }
        }
        try {
            ThreadGroup g = Thread.currentThread().getThreadGroup();
            while (g != null && g.getParent() != null) g = g.getParent();
            return g == null ? -1 : g.activeCount();
        } catch (Throwable t) {
            return -1;
        }
    }

    // ── process-kill guard ───────────────────────────────────────────────────
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

    // ── native threat telemetry ──────────────────────────────────────────────
    // Tracks which native threat callbacks have fired; emitted alongside the
    // FNatives.z return so we can see which RASP signals arrived before signing.
    private void hookThreatCallback(final ClassLoader cl, final String className,
                                    final String method, final String threatName) {
        try {
            XposedHelpers.findAndHookMethod(className, cl, method, new XC_MethodHook() {
                protected void beforeHookedMethod(MethodHookParam p) {
                    synchronized (firedThreatsLock) {
                        firedThreats.add(threatName);
                    }
                    XposedBridge.log(TAG + "native threat detected: " + threatName);
                }
            });
        } catch (Throwable t) {
            XposedBridge.log(TAG + "threat telemetry hook " + threatName + " note: " + t);
        }
    }

    // ── AppiCrypt / FNatives hooks ───────────────────────────────────────────
    private void hookAppiCryptInputs(final ClassLoader cl) {
        // Do not depend on the obfuscated config-builder class name: it changed
        // in v24. The signed configuration remains an org.json.JSONObject, so
        // mutate only the documented checks schema immediately before it is
        // serialized for the native signer. This does not replace FNatives.z().
        try {
            XposedHelpers.findAndHookMethod("org.json.JSONObject", cl, "toString",
                new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        if (SPOOF_APPICRYPT_CHECKS) {
                            try {
                                if (LOG_FULL_CHECKS_JSON) {
                                    // Log the entire checks sub-tree once per session so we
                                    // have a record of every key/status pair in the schema.
                                    String full = fullChecksJson(p.thisObject);
                                    if (full != null && !loggedAppiCryptCheckSchema) {
                                        XposedBridge.log(TAG + "AppiCrypt full checks JSON (pre-mutation): " + full);
                                    }
                                }
                                String checkSummary = summarizeCheckStatuses(p.thisObject);
                                if (spoofAppiCryptCheckStatuses(p.thisObject)) {
                                    if (!loggedAppiCryptCheckSchema) {
                                        loggedAppiCryptCheckSchema = true;
                                        XposedBridge.log(TAG + "AppiCrypt check states before mutation: "
                                            + checkSummary);
                                    }
                                    XposedBridge.log(TAG
                                        + "AppiCrypt checks schema matched; "
                                        + "unofficialStore/privilegedAccess set to OK before signing");
                                }
                            } catch (Throwable t) {
                                XposedBridge.log(TAG + "AppiCrypt schema mutation FAILED: " + t);
                            }
                        }
                    }
                });
            XposedBridge.log(TAG + "AppiCrypt pre-signing JSON schema hook installed");
        } catch (Throwable t) { XposedBridge.log(TAG + "AppiCrypt JSON schema hook FAILED: " + t); }

        // Pre-v24 interface retained only as a diagnostic. It has a String kid,
        // five byte arrays, and a long config CRC.
        try {
            Class<?> contextClass = XposedHelpers.findClass("android.content.Context", cl);
            XposedHelpers.findAndHookMethod("androidx.security.FNatives", cl, "z",
                contextClass, byte[].class, String.class, byte[].class,
                byte[].class, byte[].class, long.class, new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        byte[] nonce = (byte[]) p.args[3];
                        byte[] dataToSign = (byte[]) p.args[4];
                        XposedBridge.log(TAG + "FNatives.z legacy interface:"
                            + " nonceLen=" + length(nonce)
                            + " dataToSignLen=" + length(dataToSign)
                            + " dataShape=" + appiCryptDataShape(dataToSign));
                    }
                });
            XposedBridge.log(TAG + "FNatives.z legacy metadata probe installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "FNatives.z legacy probe note: " + t);
        }

        // Diskwala v24 changed z() to Context + six byte arrays + two flags.
        // Keep this observational: the native signer is still called normally.
        // afterHookedMethod now emits the return-value size and the threats that
        // fired before this call — key data for diagnosing the cryptogram content.
        try {
            Class<?> contextClass = XposedHelpers.findClass("android.content.Context", cl);
            XposedHelpers.findAndHookMethod("androidx.security.FNatives", cl, "z",
                contextClass, byte[].class, byte[].class, byte[].class,
                byte[].class, byte[].class, byte[].class, byte.class, byte.class,
                new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        byte[] nonce = (byte[]) p.args[3];
                        byte[] dataToSign = (byte[]) p.args[4];
                        XposedBridge.log(TAG + "FNatives.z v24 interface:"
                            + " nonceLen=" + length(nonce)
                            + " dataToSignLen=" + length(dataToSign)
                            + " dataShape=" + appiCryptDataShape(dataToSign)
                            + " threatsBeforeSigning=[" + joinThreats() + "]");
                    }
                    protected void afterHookedMethod(MethodHookParam p) {
                        if (!LOG_FNATIVES_Z_RETURN) return;
                        Object result = p.getResult();
                        String info;
                        if (result == null) {
                            info = "null";
                        } else if (result instanceof String) {
                            info = "len=" + ((String) result).length();
                        } else {
                            info = result.getClass().getSimpleName();
                        }
                        XposedBridge.log(TAG + "FNatives.z v24 returned: " + info
                            + " threatsAtReturn=[" + joinThreats() + "]");
                    }
                });
            XposedBridge.log(TAG + "FNatives.z v24 metadata probe installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "FNatives.z v24 probe FAILED: " + t);
        }

        // FNatives.y is the second native protected operation in libts.so.
        // It may be called during SDK initialisation or key-derivation. Logging
        // call/return lets us see when it's invoked relative to the v3 request.
        if (LOG_FNATIVES_Y) {
            try {
                XposedHelpers.findAndHookMethod("androidx.security.FNatives", cl, "y",
                    byte[].class, byte[].class, byte[].class, byte[].class,
                    byte.class, byte.class, new XC_MethodHook() {
                        protected void beforeHookedMethod(MethodHookParam p) {
                            XposedBridge.log(TAG + "FNatives.y called:"
                                + " arg0len=" + length((byte[]) p.args[0])
                                + " arg1len=" + length((byte[]) p.args[1]));
                        }
                        protected void afterHookedMethod(MethodHookParam p) {
                            Object r = p.getResult();
                            String info = (r instanceof byte[])
                                ? "len=" + ((byte[]) r).length : (r == null ? "null" : r.getClass().getSimpleName());
                            XposedBridge.log(TAG + "FNatives.y returned: " + info);
                        }
                    });
                XposedBridge.log(TAG + "FNatives.y probe installed");
            } catch (Throwable t) {
                XposedBridge.log(TAG + "FNatives.y probe note: " + t);
            }
        }
    }

    // ── install-source telemetry ─────────────────────────────────────────────
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

    // ── device-ID override (accepted-session A/B) ────────────────────────────
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

    // ── NEW: identifier telemetry ────────────────────────────────────────────
    // Hook WritableNativeMap.putString() and log the four identifier values that
    // getIdentifiers() writes into the result map. Only the key name and whether
    // the value is empty/present (+ length) are emitted — no raw identifier bytes.
    //
    // Diagnostic target: we need to confirm whether mediaDrm is always empty in
    // this Redroid build (expected) and see the fingerprintV3 / androidId lengths.
    // An empty mediaDrm is a server-visible Redroid fingerprint embedded in tCfg.
    private void hookGetIdentifiers(final ClassLoader cl) {
        try {
            Class<?> mapClass = XposedHelpers.findClass(
                "com.facebook.react.bridge.WritableNativeMap", cl);
            XposedHelpers.findAndHookMethod(mapClass, "putString",
                String.class, String.class, new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        String key = (String) p.args[0];
                        if (!"sessionId".equals(key) && !"androidId".equals(key)
                                && !"mediaDrm".equals(key) && !"fingerprintV3".equals(key)) {
                            return;
                        }
                        String value = (String) p.args[1];
                        boolean empty = (value == null || value.isEmpty());
                        XposedBridge.log(TAG + "identifier put: " + key + "="
                            + (empty ? "EMPTY" : "present[" + value.length() + "chars]"));
                    }
                });
            XposedBridge.log(TAG + "identifier logging hook installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "identifier hook note: " + t);
        }
    }

    // ── NEW: RASP execution-state channel desync ─────────────────────────────
    // The threat channel (getThreatChannelData) was already desynced. The RASP
    // execution-state channel (getRaspExecutionStateChannelData) is a separate
    // NativeEventEmitter channel that delivers SDK execution-lifecycle events.
    // Desync it with the same dead-channel technique so no RASP execution state
    // can reach JS and trigger a secondary client-side reaction.
    private void hookRaspExecutionState(final ClassLoader cl) {
        try {
            XposedHelpers.findAndHookMethod(PLUGIN, cl, "getRaspExecutionStateChannelData",
                "com.facebook.react.bridge.Promise", new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        try {
                            Class<?> argsClass = XposedHelpers.findClass(
                                "com.facebook.react.bridge.Arguments", cl);
                            Object arr = XposedHelpers.callStaticMethod(argsClass, "createArray");
                            XposedHelpers.callMethod(arr, "pushString", "dead_rasp_ch_a");
                            XposedHelpers.callMethod(arr, "pushString", "dead_rasp_ch_b");
                            XposedHelpers.callMethod(p.args[0], "resolve", arr);
                            p.setResult(null);
                            XposedBridge.log(TAG + "getRaspExecutionStateChannelData -> DESYNCED");
                        } catch (Throwable t) {
                            XposedBridge.log(TAG + "RASP state desync err: " + t);
                        }
                    }
                });
            XposedBridge.log(TAG + "getRaspExecutionStateChannelData desync installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "getRaspExecutionStateChannelData hook FAILED: " + t);
        }
    }

    // ── NEW: Play Integrity request telemetry ────────────────────────────────
    // Logs the nonce length and cloud-project number for every requestToken call
    // so we can verify the nonce binding and confirm the project number matches
    // the one hardcoded in the bundle (219619808378). Never logs the nonce value,
    // the resulting token, or any other sensitive material.
    private void hookPlayIntegrityRequest(final ClassLoader cl) {
        try {
            XposedHelpers.findAndHookMethod(
                TARGET_PACKAGE + ".integrity.PlayIntegrityModule", cl, "requestToken",
                String.class, String.class,
                "com.facebook.react.bridge.Promise", new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        String nonce = (String) p.args[0];
                        String cloudProject = (String) p.args[1];
                        XposedBridge.log(TAG + "PlayIntegrity.requestToken: nonceLen="
                            + (nonce == null ? "null" : nonce.length())
                            + " cloudProject=" + cloudProject);
                    }
                    protected void afterHookedMethod(MethodHookParam p) {
                        if (p.getThrowable() != null) {
                            XposedBridge.log(TAG + "PlayIntegrity.requestToken threw: " + p.getThrowable());
                        } else {
                            XposedBridge.log(TAG + "PlayIntegrity.requestToken: request submitted to GMS");
                        }
                    }
                });
            XposedBridge.log(TAG + "PlayIntegrity request logging hook installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "PlayIntegrity hook note: " + t);
        }
    }

    // ── NEW: getCryptogram outcome telemetry ─────────────────────────────────
    // Logs whether getCryptogram() completes normally or throws/rejects so we can
    // distinguish a cryptogram-generation failure from a server-side rejection.
    // Does NOT log the cryptogram value or the nonce.
    private void hookCryptogramResult(final ClassLoader cl) {
        try {
            XposedHelpers.findAndHookMethod(PLUGIN, cl, "getCryptogram",
                String.class, "com.facebook.react.bridge.Promise", new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        String nonce = (String) p.args[0];
                        XposedBridge.log(TAG + "getCryptogram: entry nonceLen="
                            + (nonce == null ? "null" : nonce.length()));
                    }
                    protected void afterHookedMethod(MethodHookParam p) {
                        if (p.getThrowable() != null) {
                            XposedBridge.log(TAG + "getCryptogram: method threw " + p.getThrowable());
                        } else {
                            XposedBridge.log(TAG + "getCryptogram: method completed normally");
                        }
                    }
                });
            XposedBridge.log(TAG + "getCryptogram logging hook installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "getCryptogram hook note: " + t);
        }
    }

    // RevenueCat 9.12.0's normal CACHED_OR_FETCHED path synchronises pending
    // Play purchases before a cache-miss fetch. On this Redroid image the Play
    // Billing client remains in CONNECTING, leaving the React Native Promise
    // unresolved and FileInfo permanently loading. Return a complete cached
    // CustomerInfo through RevenueCat's own mapper when one exists. Diskwala
    // already handles null as non-premium, so use null on a cache miss rather
    // than leaving the Promise pending forever.
    private void hookCachedRevenueCatCustomerInfo(final ClassLoader cl) {
        try {
            XposedHelpers.findAndHookMethod(
                "com.revenuecat.purchases.react.RNPurchasesModule", cl,
                "getCustomerInfo", "com.facebook.react.bridge.Promise",
                new XC_MethodHook() {
                    protected void beforeHookedMethod(MethodHookParam p) {
                        try {
                            Class<?> purchasesClass = XposedHelpers.findClass(
                                "com.revenuecat.purchases.Purchases", cl);
                            Object companion = XposedHelpers.getStaticObjectField(
                                purchasesClass, "Companion");
                            Object purchases = XposedHelpers.callMethod(
                                companion, "getSharedInstance");
                            String appUserId = (String) XposedHelpers.callMethod(
                                purchases, "getAppUserID");
                            Object orchestrator = XposedHelpers.getObjectField(
                                purchases, "purchasesOrchestrator");
                            Object deviceCache = XposedHelpers.getObjectField(
                                orchestrator, "deviceCache");
                            Object customerInfo = XposedHelpers.callMethod(
                                deviceCache, "getCachedCustomerInfo", appUserId);
                            if (customerInfo == null) {
                                // Diskwala already treats null CustomerInfo as a
                                // non-premium state. Resolving null is preferable
                                // to leaving every FileInfo request blocked behind
                                // a BillingClient connection that never completes.
                                XposedHelpers.callMethod(p.args[0], "resolve", (Object) null);
                                p.setResult(null);
                                XposedBridge.log(TAG + "RevenueCat CustomerInfo cache miss; resolved null");
                                return;
                            }

                            Class<?> mapper = XposedHelpers.findClass(
                                "com.revenuecat.purchases.hybridcommon.mappers.CustomerInfoMapperKt", cl);
                            Object mapped = XposedHelpers.callStaticMethod(
                                mapper, "map", customerInfo);
                            Class<?> arguments = XposedHelpers.findClass(
                                "com.facebook.react.bridge.Arguments", cl);
                            Object nativeMap = XposedHelpers.callStaticMethod(
                                arguments, "makeNativeMap", mapped);
                            XposedHelpers.callMethod(p.args[0], "resolve", nativeMap);
                            p.setResult(null);
                            XposedBridge.log(TAG + "RevenueCat getCustomerInfo resolved from native cache");
                        } catch (Throwable t) {
                            // Preserve the SDK's original behaviour if its object
                            // graph or mapper changes in a future app release.
                            XposedBridge.log(TAG + "RevenueCat cache hook fallback: "
                                + t.getClass().getName());
                        }
                    }
                });
            XposedBridge.log(TAG + "RevenueCat native-cache hook installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "RevenueCat cache hook note: " + t);
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────────
    private static int length(byte[] value) {
        return value == null ? -1 : value.length;
    }

    private static String unitFingerprint(String adUnitId) {
        return Integer.toHexString(adUnitId.hashCode());
    }

    private static String joinThreats() {
        synchronized (firedThreatsLock) {
            if (firedThreats.isEmpty()) return "none";
            StringBuilder sb = new StringBuilder();
            for (String t : firedThreats) {
                if (sb.length() > 0) sb.append(',');
                sb.append(t);
            }
            return sb.toString();
        }
    }

    // Mutate the AppiCrypt checks JSON before the native signer serialises it.
    //
    // SPOOF_ALL_NOK_CHECKS=true (default): iterate every key in the checks object
    // and force any NOK status to OK. This is a strict superset of the original
    // two-key behaviour and ensures we cover any check type that is or becomes NOK
    // in the Redroid environment without needing to name it explicitly.
    //
    // Returns true only when the JSONObject is a Talsec checks schema (has a
    // "checks" sub-object) so callers know whether this is the right object.
    private static boolean spoofAppiCryptCheckStatuses(Object root) {
        Object checks = XposedHelpers.callMethod(root, "optJSONObject", "checks");
        if (checks == null) return false;

        if (!SPOOF_ALL_NOK_CHECKS) {
            // Original selective mutation kept as a fallback path.
            Object unofficialStore = XposedHelpers.callMethod(checks, "optJSONObject", "unofficialStore");
            Object privilegedAccess = XposedHelpers.callMethod(checks, "optJSONObject", "privilegedAccess");
            if (unofficialStore == null || privilegedAccess == null) return false;
            boolean changed = false;
            if ("NOK".equals(XposedHelpers.callMethod(unofficialStore, "optString", "status", ""))) {
                XposedHelpers.callMethod(unofficialStore, "put", "status", "OK");
                changed = true;
            }
            if ("NOK".equals(XposedHelpers.callMethod(privilegedAccess, "optString", "status", ""))) {
                XposedHelpers.callMethod(privilegedAccess, "put", "status", "OK");
                changed = true;
            }
            return changed;
        }

        // Blanket mode: walk every check key and force NOK -> OK.
        boolean changed = false;
        try {
            Object iteratorObject = XposedHelpers.callMethod(checks, "keys");
            if (!(iteratorObject instanceof Iterator)) return false;
            Iterator<?> iterator = (Iterator<?>) iteratorObject;
            while (iterator.hasNext()) {
                String name = String.valueOf(iterator.next());
                Object check = XposedHelpers.callMethod(checks, "optJSONObject", name);
                if (check == null) continue;
                String status = String.valueOf(
                    XposedHelpers.callMethod(check, "optString", "status", ""));
                if ("NOK".equals(status)) {
                    XposedHelpers.callMethod(check, "put", "status", "OK");
                    XposedBridge.log(TAG + "AppiCrypt blanket-mutated: " + name + " NOK -> OK");
                    changed = true;
                }
            }
        } catch (Throwable t) {
            XposedBridge.log(TAG + "blanket mutation iterate failed: " + t);
        }
        return changed;
    }

    // Returns the full serialised checks sub-object as a string, used for the
    // one-time full-JSON diagnostic log. Never called unless LOG_FULL_CHECKS_JSON.
    private static String fullChecksJson(Object root) {
        try {
            Object checks = XposedHelpers.callMethod(root, "optJSONObject", "checks");
            if (checks == null) return null;
            return String.valueOf(XposedHelpers.callMethod(checks, "toString"));
        } catch (Throwable t) {
            return "error:" + t.getMessage();
        }
    }

    // Diagnostic output is deliberately limited to check names and their
    // OK/NOK state. It does not log config JSON, identifiers, headers, nonce,
    // cryptogram, or any device-state value.
    private static String summarizeCheckStatuses(Object root) {
        try {
            Object checks = XposedHelpers.callMethod(root, "optJSONObject", "checks");
            if (checks == null) return "missing";
            Object iteratorObject = XposedHelpers.callMethod(checks, "keys");
            if (!(iteratorObject instanceof Iterator)) return "unavailable";
            Iterator<?> iterator = (Iterator<?>) iteratorObject;
            StringBuilder out = new StringBuilder();
            while (iterator.hasNext()) {
                String name = String.valueOf(iterator.next());
                Object check = XposedHelpers.callMethod(checks, "optJSONObject", name);
                if (check == null) continue;
                String status = String.valueOf(
                    XposedHelpers.callMethod(check, "optString", "status", "unknown"));
                if (out.length() > 0) out.append(',');
                out.append(name).append('=').append(status);
            }
            return out.length() == 0 ? "empty" : out.toString();
        } catch (Throwable ignored) {
            return "unavailable";
        }
    }

    private static boolean hasAcceptedDeviceId() {
        return !SPOOF_DEVICE_ID.startsWith(DEVICE_ID_PLACEHOLDER_PREFIX);
    }

    private static String appiCryptDataShape(byte[] value) {
        if (value == null) return "null";
        String text = new String(value);
        return text.contains("\"checks\"") ? "json-checks" : "opaque";
    }
}
