package com.recon.dw26gate;

import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * Standalone entry point for the DiskWala request signer. Runs OUTSIDE the
 * PairIP-protected app, as com.diskwalaapp's uid, launched via:
 *
 *   . /data/local/tmp/andenv.sh   # BOOTCLASSPATH/DEX2OATBOOTCLASSPATH/ANDROID_* + CLASSPATH=dwsigner.jar
 *   su 10107 sh -c 'exec app_process /system/bin com.recon.dw26gate.SignerMain /data/data/com.diskwalaapp'
 *
 * keystore2 authorises app keys by uid, so this process can use
 * com.diskwalaapp.attest.ec.v1 without the app (and therefore PairIP) ever
 * running. It reuses the exact request-proof logic of the LSPosed variant
 * ({@link SignerBridge}/{@link AndroidKeyStoreSigner}/{@link SignerPolicy}) and
 * serves the identical loopback protocol expected by dw_signer_client.py.
 */
public final class SignerMain {
    private SignerMain() {}

    public static void main(String[] args) {
        String dataDir = args.length > 0 ? args[0] : "/data/data/com.diskwalaapp";
        String logPath = args.length > 1 ? args[1] : dataDir + "/files/dw26gate/signer.log";
        PrintStream log = openLog(logPath);
        installKeystoreProvider(log);
        try {
            SignerBridge.start(dataDir, message -> {
                log.println(now() + " " + message);
                log.flush();
            });
            log.println(now() + " SIGNER standalone up uid=" + android.os.Process.myUid()
                + " port=" + SignerBridge.PORT + " dataDir=" + dataDir);
            log.flush();
            // The serve loop runs on a daemon thread; keep this (non-daemon) main
            // thread alive so the process stays up until the container stops.
            Object forever = new Object();
            synchronized (forever) {
                while (true) forever.wait();
            }
        } catch (Throwable fatal) {
            log.println(now() + " FATAL " + fatal.getClass().getName() + ": " + fatal.getMessage());
            fatal.printStackTrace(log);
            log.flush();
            System.exit(1);
        }
    }

    /**
     * A bare app_process does not register the AndroidKeyStore JCA provider (the
     * framework normally does this during app init) and enforces hidden-API
     * access. Lift the exemption and install the provider by reflection so we do
     * not need a compile-time dependency on the @hide class.
     */
    private static void installKeystoreProvider(PrintStream log) {
        try {
            Class<?> vmRuntime = Class.forName("dalvik.system.VMRuntime");
            Object runtime = vmRuntime.getMethod("getRuntime").invoke(null);
            vmRuntime.getMethod("setHiddenApiExemptions", String[].class)
                .invoke(runtime, (Object) new String[] {"L"});
        } catch (Throwable ignored) {
            log.println(now() + " hiddenapi-exempt-skipped " + ignored);
        }
        try {
            Class.forName("android.security.keystore2.AndroidKeyStoreProvider")
                .getMethod("install").invoke(null);
        } catch (Throwable modern) {
            try {
                Class.forName("android.security.keystore.AndroidKeyStoreProvider")
                    .getMethod("install").invoke(null);
            } catch (Throwable legacy) {
                log.println(now() + " provider-install-FAILED modern=" + modern + " legacy=" + legacy);
            }
        }
    }

    private static PrintStream openLog(String path) {
        try {
            File file = new File(path);
            File parent = file.getParentFile();
            if (parent != null) parent.mkdirs();
            return new PrintStream(new FileOutputStream(file, true), true, "UTF-8");
        } catch (Throwable fallback) {
            return System.err;
        }
    }

    private static String now() {
        return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT).format(new Date());
    }
}
