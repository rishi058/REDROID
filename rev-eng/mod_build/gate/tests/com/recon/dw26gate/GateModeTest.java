package com.recon.dw26gate;

public final class GateModeTest {
    private static void expect(GateMode expected, String input) {
        GateMode actual = GateMode.parse(input);
        if (expected != actual) {
            throw new AssertionError("Expected " + expected + "; got " + actual);
        }
    }

    public static void main(String[] args) {
        expect(GateMode.OBSERVE, null);
        expect(GateMode.OBSERVE, "");
        expect(GateMode.OBSERVE, "unknown");
        expect(GateMode.OBSERVE, "local-bypass-everything");
        expect(GateMode.OBSERVE, "observe");
        expect(GateMode.LOCAL, "local");
        expect(GateMode.LOCAL, " LOCAL\n");
        expect(GateMode.OFF, "off");
        expect(GateMode.MOCK, "mock");
        expect(GateMode.OBSERVE, " ".repeat(65) + "local");
        System.out.println("GateModeTest: 10 cases passed");
    }
}
