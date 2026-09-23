#!/usr/bin/env python3
import argparse
import re
import subprocess
import time
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description="Inspect/open Google chooser without selecting an account")
    parser.add_argument("--serial", required=True, help="Verified local ADB serial")
    parser.add_argument("--inspect", action="store_true", help="Inspect current UI only")
    args = parser.parse_args()
    adb_base = ["adb", "-s", args.serial]

    def adb(*command):
        return subprocess.run(adb_base + list(command), check=True, capture_output=True,
                              text=True, encoding="utf-8", errors="replace", timeout=25).stdout

    def snapshot():
        adb("shell", "uiautomator", "dump", "/data/local/tmp/dw26-google-chooser.xml")
        return ET.fromstring(adb("exec-out", "cat", "/data/local/tmp/dw26-google-chooser.xml"))

    def report(root):
        packages = sorted({n.get("package", "") for n in root.iter("node")})
        labels = {"Continue with Google", "This device isn't supported", "Retry", "Home",
                  "Files", "Sign in", "Choose an account", "Loading", "Update"}
        print("UI packages:", packages)
        print("Known labels:", sorted({n.get("text") for n in root.iter("node") if n.get("text") in labels}))
        print("Account-labelled rows present:", any("@" in n.get("text", "") for n in root.iter("node")))

    if args.inspect:
        report(snapshot())
        return

    adb("shell", "am", "force-stop", "com.diskwalaapp")
    adb("shell", "am", "start", "-n", "com.diskwalaapp/.app.MainActivity")
    time.sleep(7)
    root = snapshot()
    matches = [n for n in root.iter("node") if n.get("package") == "com.diskwalaapp"
               and n.get("text") == "Continue with Google"]
    if len(matches) != 1:
        raise SystemExit("Expected sign-in button not found; no input sent")
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", matches[0].get("bounds", "")))
    adb("shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2))
    time.sleep(6)
    root = snapshot()
    report(root)
    packages = {n.get("package", "") for n in root.iter("node")}
    print("Credential UI present:", bool(packages & {"com.google.android.gms", "com.android.credentialmanager"}))
    print("No account selected; no consent button pressed.")


if __name__ == "__main__":
    main()
