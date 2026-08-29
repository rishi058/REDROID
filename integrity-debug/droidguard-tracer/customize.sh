#!/system/bin/sh
# DroidGuard Signal Tracer - install stage.
SKIPUNZIP=0
ui_print "- DroidGuard Signal Tracer/Harmonizer v0.1"
ui_print "- Diagnostic tracer installs to /data/adb/droidguard_tracer/"
ui_print "- Prop harmonization is OPT-IN:"
ui_print "    touch /data/adb/droidguard_tracer/harmonize  then reboot/restart"
ui_print "- Deeper signal harmonization (sensors/kernel/hardware/keystore) requires"
ui_print "  the Zygisk component described in README.md - NOT included in this diag build."
set_perm_recursive "$MODPATH" 0 0 0755 0644
