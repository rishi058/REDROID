package com.recon.pgstrace;

/** Pure guards and metadata shape for the parent-owned Play Store hook. */
public final class TracePolicy {
    public static final String PLAY_STORE_PACKAGE = "com.android.vending";
    public static final String PLAY_STORE_MAIN_PROCESS = "com.android.vending";
    public static final String PLAY_STORE_BACKGROUND_PROCESS = "com.android.vending:background";
    public static final String TARGET_PACKAGE = "com.diskwalaapp";
    public static final long TARGET_VERSION_CODE = 356L;
    public static final String PLAY_STORE_BASE_APK_SHA256 =
        "ab89dd8ac35b6548f54ae761cb8e5d5b182602fc02b95650722c60f60c3929c7";
    public static final int MAX_EVENTS = 32;

    private TracePolicy() {}

    public static boolean isAllowedPlayStoreProcess(String packageName, String processName) {
        return PLAY_STORE_PACKAGE.equals(packageName)
            && (PLAY_STORE_MAIN_PROCESS.equals(processName)
                || PLAY_STORE_BACKGROUND_PROCESS.equals(processName));
    }

    public static boolean isTargetDiskWala(String packageName, long versionCode) {
        return TARGET_PACKAGE.equals(packageName)
            && TARGET_VERSION_CODE == versionCode;
    }

    public static boolean isVerifiedPlayStore(
            String packageName, String processName, String playBaseApkSha256) {
        return isAllowedPlayStoreProcess(packageName, processName)
            && PLAY_STORE_BASE_APK_SHA256.equals(playBaseApkSha256);
    }

    /** The parent Hook reads the local flag; only the exact one-character value enables tracing. */
    public static boolean isEnabledFlag(String flagContents) {
        return "1".equals(flagContents);
    }

    public static boolean shouldTrace(
            String loadedPackage, String loadedProcess, String targetPackage,
            long targetVersionCode, String playBaseApkSha256, String enabledFlag) {
        return isEnabledFlag(enabledFlag)
            && isVerifiedPlayStore(loadedPackage, loadedProcess, playBaseApkSha256)
            && isTargetDiskWala(targetPackage, targetVersionCode);
    }

    public static String statusLabel(int rawStatus) {
        switch (rawStatus) {
            case 0: return "UNKNOWN";
            case 1: return "SUCCESS";
            case 2: return "NOT_TRUSTED";
            case 3: return "ENCRYPTION_KEY_NOT_REQUIRED";
            case 4: return "NOT_LICENSED";
            default: return "UNRECOGNIZED";
        }
    }

    /** Event metadata intentionally carries primitives only, never payload buffers or tokens. */
    public static EventMetadata metadata(
            boolean requestPresent, int requestLength, boolean responsePresent, int responseLength) {
        return new EventMetadata(requestPresent, requestLength, responsePresent, responseLength);
    }

    public static final class EventMetadata {
        private final boolean requestPresent;
        private final int requestLength;
        private final boolean responsePresent;
        private final int responseLength;

        private EventMetadata(
                boolean requestPresent, int requestLength,
                boolean responsePresent, int responseLength) {
            this.requestPresent = requestPresent;
            this.requestLength = requestLength;
            this.responsePresent = responsePresent;
            this.responseLength = responseLength;
        }

        public boolean requestPresent() {
            return requestPresent;
        }

        public int requestLength() {
            return requestLength;
        }

        public boolean responsePresent() {
            return responsePresent;
        }

        public int responseLength() {
            return responseLength;
        }
    }
}
