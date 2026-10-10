package com.recon.attestdump;

import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.Enumeration;

/**
 * Standalone AndroidKeyStore certificate-chain dumper. Runs as com.diskwalaapp's
 * uid via app_process (keystore2 authorises app keys by uid), so it reads the
 * enrolled attestation key WITHOUT launching the PairIP-protected app.
 *
 *   . /data/local/tmp/andenv.sh
 *   export CLASSPATH=/data/local/tmp/attestdump.jar
 *   su 10107 sh -c 'exec app_process /system/bin com.recon.attestdump.AttestDump <alias> <outfile>'
 *
 * Writes, for every alias: the alias name; and for the requested alias: each
 * certificate in the chain as base64(DER), one per line, tagged CERT[i]=.
 * The attestation extension is extracted offline with cryptography in Python.
 */
public final class AttestDump {
    private AttestDump() {}

    public static void main(String[] args) {
        String alias = args.length > 0 ? args[0] : "com.diskwalaapp.attest.ec.v1";
        String outPath = args.length > 1 ? args[1]
            : "/data/data/com.diskwalaapp/files/attestdump/chain.txt";
        PrintStream out = openOut(outPath);
        try {
            installKeystoreProvider(out);
            KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
            ks.load(null);
            out.println("UID=" + android.os.Process.myUid());
            out.println("=== ALIASES ===");
            for (Enumeration<String> e = ks.aliases(); e.hasMoreElements(); ) {
                out.println("ALIAS=" + e.nextElement());
            }
            out.println("=== TARGET " + alias + " ===");
            Certificate[] chain = ks.getCertificateChain(alias);
            if (chain == null) {
                out.println("CHAIN=null (alias absent or no cert chain)");
            } else {
                out.println("CHAIN_LEN=" + chain.length);
                for (int i = 0; i < chain.length; i++) {
                    byte[] der = chain[i].getEncoded();
                    out.println("CERT[" + i + "]=" + Base64.getEncoder().encodeToString(der));
                    if (chain[i] instanceof X509Certificate) {
                        byte[] ext = ((X509Certificate) chain[i])
                            .getExtensionValue("1.3.6.1.4.1.11129.2.1.17");
                        if (ext != null) {
                            out.println("ATTEST_EXT_WRAPPED[" + i + "]="
                                + Base64.getEncoder().encodeToString(ext));
                        }
                    }
                }
            }
            out.println("DONE_OK");
        } catch (Throwable t) {
            out.println("ERROR " + t.getClass().getName() + ": " + t.getMessage());
            t.printStackTrace(out);
        } finally {
            out.flush();
            out.close();
        }
    }

    private static void installKeystoreProvider(PrintStream out) {
        try {
            Class<?> vmRuntime = Class.forName("dalvik.system.VMRuntime");
            Object runtime = vmRuntime.getMethod("getRuntime").invoke(null);
            vmRuntime.getMethod("setHiddenApiExemptions", String[].class)
                .invoke(runtime, (Object) new String[] {"L"});
        } catch (Throwable ignored) {
            out.println("hiddenapi-exempt-skipped " + ignored);
        }
        try {
            Class.forName("android.security.keystore2.AndroidKeyStoreProvider")
                .getMethod("install").invoke(null);
        } catch (Throwable modern) {
            try {
                Class.forName("android.security.keystore.AndroidKeyStoreProvider")
                    .getMethod("install").invoke(null);
            } catch (Throwable legacy) {
                out.println("provider-install-FAILED modern=" + modern + " legacy=" + legacy);
            }
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
