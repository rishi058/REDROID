package com.google.android.gms.common.internal;

import android.os.Looper;
import android.text.TextUtils;

/**
 * Minimal drop-in for com.google.android.gms.common.internal.Preconditions.
 *
 * The classic Play Integrity client (vendored into this jar) references this one
 * play-services-basement utility for argument checks. Shimming it — instead of
 * vendoring basement, which drags in androidx and breaks dexing — keeps the jar to
 * android.jar + the three Play libraries. Method signatures (and their erased
 * descriptors) match GMS so the vendored bytecode's invokestatic calls resolve.
 */
public final class Preconditions {

    private Preconditions() {}

    public static void checkArgument(boolean expression) {
        if (!expression) {
            throw new IllegalArgumentException();
        }
    }

    public static void checkArgument(boolean expression, Object errorMessage) {
        if (!expression) {
            throw new IllegalArgumentException(String.valueOf(errorMessage));
        }
    }

    public static int checkArgumentInRange(int value, int lower, int upper, String name) {
        if (value < lower || value > upper) {
            throw new IllegalArgumentException(name + " out of range");
        }
        return value;
    }

    public static <T> T checkNotNull(T reference) {
        if (reference == null) {
            throw new NullPointerException("null reference");
        }
        return reference;
    }

    public static <T> T checkNotNull(T reference, Object errorMessage) {
        if (reference == null) {
            throw new NullPointerException(String.valueOf(errorMessage));
        }
        return reference;
    }

    public static String checkNotEmpty(String string) {
        if (TextUtils.isEmpty(string)) {
            throw new IllegalArgumentException("Given String is empty or null");
        }
        return string;
    }

    public static String checkNotEmpty(String string, Object errorMessage) {
        if (TextUtils.isEmpty(string)) {
            throw new IllegalArgumentException(String.valueOf(errorMessage));
        }
        return string;
    }

    public static void checkState(boolean expression) {
        if (!expression) {
            throw new IllegalStateException();
        }
    }

    public static void checkState(boolean expression, Object errorMessage) {
        if (!expression) {
            throw new IllegalStateException(String.valueOf(errorMessage));
        }
    }

    public static void checkState(boolean expression, String template, Object... args) {
        if (!expression) {
            throw new IllegalStateException(String.format(template, args));
        }
    }

    public static void checkMainThread(String errorMessage) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            throw new IllegalStateException(errorMessage);
        }
    }

    public static void checkNotMainThread() {
        checkNotMainThread("Must not be called on the main application thread");
    }

    public static void checkNotMainThread(String errorMessage) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw new IllegalStateException(errorMessage);
        }
    }

    public static void checkNotGoogleApiHandlerThread() {
        // No internal GoogleApi handler thread exists in this standalone client,
        // so there is nothing to guard against blocking.
    }
}
