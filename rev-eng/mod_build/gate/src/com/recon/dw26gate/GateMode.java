package com.recon.dw26gate;

import java.util.Locale;

/** Unknown or missing configuration must never enable a behavioral override. */
enum GateMode {
    OFF, OBSERVE, LOCAL, MOCK, SIGNER;

    static GateMode parse(String value) {
        if (value == null || value.length() > 64) return OBSERVE;
        switch (value.trim().toLowerCase(Locale.ROOT)) {
            case "off": return OFF;
            case "local": return LOCAL;
            case "mock": return MOCK;
            case "signer": return SIGNER;
            case "observe":
            default: return OBSERVE;
        }
    }
}
