package com.recon.integrity;

import android.content.Context;
import android.os.Looper;

import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.util.concurrent.TimeUnit;

/**
 * Mint a genuine Play Integrity token AS com.diskwalaapp, without launching the
 * app — so PairIP's native anti-tamper (which runs at app startup / libpairipcore
 * load) never runs, and no Frida/Xposed injection is needed.
 *
 * keystore2 authorizes by uid; Play Integrity (GMS) likewise attributes the caller
 * by Binder uid + package. Run as the app's uid via app_process:
 *
 *   . /data/local/tmp/andenv.sh
 *   export CLASSPATH=/data/local/tmp/integrity.jar
 *   su 10107 sh -c 'exec app_process /system/bin com.recon.integrity.IntegrityMain \
 *       <nonce/challenge> <outfile> [cloudProjectNumber] [package]'
 *
 * We build a Context for com.diskwalaapp (its classloader includes the bundled
 * Play Integrity client + GMS Tasks), then call the classic API by reflection:
 *   IntegrityManagerFactory.create(ctx)
 *       .requestIntegrityToken(IntegrityTokenRequest.builder()
 *           .setNonce(nonce)[.setCloudProjectNumber(n)].build())
 *   -> Task<IntegrityTokenResponse>  ->  .token()
 *
 * The token is written to <outfile>. Only Play Integrity / GMS-Tasks classes are
 * loaded — never a PairIP class — so libpairipcore is not touched.
 */
public final class IntegrityMain {
    private IntegrityMain() {}

    private static final String PKG_DEFAULT = "com.diskwalaapp";
    private static final String FACTORY = "com.google.android.play.core.integrity.IntegrityManagerFactory";
    private static final String REQUEST = "com.google.android.play.core.integrity.IntegrityTokenRequest";
    private static final String TASKS = "com.google.android.gms.tasks.Tasks";
    private static final String TASK = "com.google.android.gms.tasks.Task";

    public static void main(String[] args) {
        if (args.length < 2) {
            System.err.println("usage: IntegrityMain <nonce> <outfile> [cloudProjectNumber] [package]");
            System.exit(2);
        }
        final String nonce = args[0];
        final String outPath = args[1];
        final Long cloudProject = args.length > 2 && !args[2].isEmpty() ? parseLong(args[2]) : null;
        final String pkg = args.length > 3 && !args[3].isEmpty() ? args[3] : PKG_DEFAULT;

        final PrintStream out = openOut(outPath);
        // The main looper serves GMS/Play callbacks but cannot be quit, so the
        // worker writes the result and hard-exits the process when it is done.
        try {
            Looper.prepareMainLooper();
            exemptHiddenApi(out);
            final Context ctx = appContext(pkg);
            out.println("CTX_OK package=" + ctx.getPackageName() + " uid=" + android.os.Process.myUid());
            out.flush();

            Thread worker = new Thread(() -> {
                int code = 1;
                try {
                    String token = requestToken(ctx, nonce, cloudProject);
                    if (token != null && !token.isEmpty()) {
                        out.println("TOKEN " + token);
                        out.println("RESULT=INTEGRITY_TOKEN_OK");
                        code = 0;
                    } else {
                        out.println("ERROR empty token");
                    }
                } catch (Throwable t) {
                    out.println("ERROR " + t.getClass().getName() + ": " + t.getMessage());
                    dumpCause(out, t);
                } finally {
                    out.flush();
                    Runtime.getRuntime().halt(code);
                }
            }, "integrity-worker");
            worker.start();
            Looper.loop();
        } catch (Throwable fatal) {
            out.println("FATAL " + fatal.getClass().getName() + ": " + fatal.getMessage());
            dumpCause(out, fatal);
            out.flush();
            Runtime.getRuntime().halt(1);
        }
    }

    /** Build a Context whose package == pkg and whose classloader includes its code. */
    private static Context appContext(String pkg) throws Exception {
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object activityThread = at.getMethod("systemMain").invoke(null);
        Context systemCtx = (Context) at.getMethod("getSystemContext").invoke(activityThread);
        int flags = Context.CONTEXT_INCLUDE_CODE | Context.CONTEXT_IGNORE_SECURITY;
        return systemCtx.createPackageContext(pkg, flags);
    }

    /** Classic Play Integrity request. The client library is bundled in THIS jar
     * (the app's own copy is inside the PairIP-encrypted dex and not loadable), so
     * resolve the classes from our classloader; GMS/Play attributes the token by
     * the caller's uid + package (the app context), not by the client classloader. */
    private static String requestToken(Context ctx, String nonce, Long cloudProject) throws Exception {
        ClassLoader cl = IntegrityMain.class.getClassLoader();
        Class<?> factory = Class.forName(FACTORY, true, cl);
        Object manager = factory.getMethod("create", Context.class).invoke(null, ctx);

        Class<?> requestClass = Class.forName(REQUEST, true, cl);
        Object builder = requestClass.getMethod("builder").invoke(null);
        Class<?> builderClass = builder.getClass();
        builder = builderClass.getMethod("setNonce", String.class).invoke(builder, nonce);
        if (cloudProject != null) {
            builderClass.getMethod("setCloudProjectNumber", long.class)
                .invoke(builder, cloudProject.longValue());
        }
        Object request = builderClass.getMethod("build").invoke(builder);

        Object task = manager.getClass()
            .getMethod("requestIntegrityToken", requestClass).invoke(manager, request);

        Class<?> tasksClass = Class.forName(TASKS, true, cl);
        Class<?> taskClass = Class.forName(TASK, true, cl);
        Method await = tasksClass.getMethod("await", taskClass, long.class, TimeUnit.class);
        Object response = await.invoke(null, task, 90L, TimeUnit.SECONDS);
        Object token = response.getClass().getMethod("token").invoke(response);
        return (String) token;
    }

    private static void exemptHiddenApi(PrintStream out) {
        try {
            Class<?> vmRuntime = Class.forName("dalvik.system.VMRuntime");
            Object runtime = vmRuntime.getMethod("getRuntime").invoke(null);
            vmRuntime.getMethod("setHiddenApiExemptions", String[].class)
                .invoke(runtime, (Object) new String[] {"L"});
        } catch (Throwable ignored) {
            out.println("hiddenapi-exempt-skipped " + ignored);
        }
    }

    private static Long parseLong(String value) {
        try {
            return Long.valueOf(value.trim());
        } catch (NumberFormatException bad) {
            return null;
        }
    }

    private static void dumpCause(PrintStream out, Throwable t) {
        Throwable cause = t;
        int depth = 0;
        while (cause != null && depth < 6) {
            out.println("  caused_by " + cause.getClass().getName() + ": " + cause.getMessage());
            cause = cause.getCause();
            depth++;
        }
    }

    private static PrintStream openOut(String path) {
        try {
            File file = new File(path);
            File parent = file.getParentFile();
            if (parent != null) parent.mkdirs();
            return new PrintStream(new FileOutputStream(file, false), true, "UTF-8");
        } catch (Throwable fallback) {
            return System.err;
        }
    }
}
