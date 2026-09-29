package com.recon.pgstrace;

public final class TracePolicyTest {
    private static int checks;
    private static void check(boolean condition) {
        checks++;
        if (!condition) throw new AssertionError("Trace policy invariant failed");
    }

    public static void main(String[] args) {
        check(TracePolicy.MAX_EVENTS == 32);
        check(TracePolicy.isAllowedPlayStoreProcess("com.android.vending", "com.android.vending"));
        check(TracePolicy.isAllowedPlayStoreProcess(
            "com.android.vending", "com.android.vending:background"));
        check(!TracePolicy.isAllowedPlayStoreProcess(
            "com.android.vending.other", "com.android.vending"));
        check(!TracePolicy.isAllowedPlayStoreProcess(
            "com.android.vending", "com.android.vending:service"));
        check(TracePolicy.isTargetDiskWala("com.diskwalaapp", 356L));
        check(!TracePolicy.isTargetDiskWala("com.diskwalaapp.other", 356L));
        check(!TracePolicy.isTargetDiskWala("com.diskwalaapp", 355L));
        check(!TracePolicy.isVerifiedPlayStore("com.android.vending", "com.android.vending",
            "AB89DD8AC35B6548F54AE761CB8E5D5B182602FC02B95650722C60F60C3929C7"));
        check(!TracePolicy.isVerifiedPlayStore("com.android.vending", "com.android.vending",
            "7789a7947b6e110d957c7c1d95d12718a83a70d3ddce3c1a3cf15542b0a5043f"));
        check(TracePolicy.isVerifiedPlayStore("com.android.vending", "com.android.vending",
            TracePolicy.PLAY_STORE_BASE_APK_SHA256));
        check(!TracePolicy.isTargetDiskWala(null, 356L));
        check(!TracePolicy.isAllowedPlayStoreProcess("com.android.vending", null));
        check(!TracePolicy.isEnabledFlag(null));
        check(!TracePolicy.isEnabledFlag(""));
        check(!TracePolicy.isEnabledFlag("1\n"));
        check(TracePolicy.isEnabledFlag("1"));
        check(!TracePolicy.shouldTrace("com.android.vending", "com.android.vending",
            "com.diskwalaapp", 356L,
            "ab89dd8ac35b6548f54ae761cb8e5d5b182602fc02b95650722c60f60c3929c7", "0"));
        check(TracePolicy.shouldTrace("com.android.vending", "com.android.vending:background",
            "com.diskwalaapp", 356L,
            "ab89dd8ac35b6548f54ae761cb8e5d5b182602fc02b95650722c60f60c3929c7", "1"));
        check("SUCCESS".equals(TracePolicy.statusLabel(1)));
        check("NOT_TRUSTED".equals(TracePolicy.statusLabel(2)));
        check("ENCRYPTION_KEY_NOT_REQUIRED".equals(TracePolicy.statusLabel(3)));
        check("NOT_LICENSED".equals(TracePolicy.statusLabel(4)));
        check("UNRECOGNIZED".equals(TracePolicy.statusLabel(99)));
        check("UNRECOGNIZED".equals(TracePolicy.statusLabel(-1)));

        TracePolicy.EventMetadata metadata = TracePolicy.metadata(true, 17, false, 0);
        check(metadata.requestPresent());
        check(metadata.requestLength() == 17);
        check(!metadata.responsePresent());
        check(metadata.responseLength() == 0);
        System.out.println("TracePolicyTest: " + checks + " cases passed");
    }
}
