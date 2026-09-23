package com.recon.dw26gate;

import java.util.Locale;

final class GatePrivacy {
    static boolean sensitive(String key) {
        String k = key.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]", "");
        return k.contains("token") || k.contains("secret") || k.contains("password")
            || k.contains("authorization") || k.contains("cookie") || k.contains("certificate")
            || k.equals("id") || k.equals("userid") || k.equals("deviceid") || k.equals("androidid")
            || k.equals("keyid") || k.equals("nonce") || k.equals("challenge") || k.equals("chain")
            || k.equals("auth") || k.equals("bearer") || k.contains("credential")
            || k.equals("access") || k.equals("refresh")
            || k.equals("user") || k.equals("profile") || k.equals("account")
            || k.equals("assertion") || k.equals("signature") || k.equals("publickey")
            || k.equals("privatekey") || k.equals("email") || k.equals("phone")
            || k.equals("tk") || k.equals("it") || k.equals("sid") || k.equals("did");
    }

    static String text(String text) {
        if (text.equals(GatePolicy.code(text))) return text;
        String result = text.replaceAll("[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", "<jwt>")
            .replaceAll("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>")
            .replaceAll("(?i)\\b[0-9a-f]{16,}\\b", "<identifier>")
            .replaceAll("[A-Za-z0-9_+/=-]{32,}", "<opaque>");
        return result.length() > 512 ? result.substring(0, 512) + "<truncated>" : result;
    }

    private GatePrivacy() {}
}
