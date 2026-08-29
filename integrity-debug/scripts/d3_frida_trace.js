/*
 * Phase D.3 - DroidGuard environment-probe tracer (Frida).
 * DEBUG ONLY: observes what signals the DroidGuard VM reads. Does NOT fake anything.
 * Attach to the isolated DroidGuard process:
 *   frida -U -f <spawn not needed> ; instead attach by name after it starts:
 *   frida -U -n com.google.android.gms.unstable -l d3_frida_trace.js --runtime=v8
 * Logs: every system-property read + every file path opened + selected libc probes.
 */
'use strict';

const SEEN = new Set();
function once(tag, v) { const k = tag + '|' + v; if (SEEN.has(k)) return false; SEEN.add(k); return true; }

// 1) system property reads -> reveals which ro.* / persist.* DroidGuard inspects
try {
  const spg = Module.findExportByName('libc.so', '__system_property_get');
  if (spg) {
    Interceptor.attach(spg, {
      onEnter(args) { this.name = args[0].readCString(); this.buf = args[1]; },
      onLeave() {
        const val = this.buf ? this.buf.readCString() : '';
        if (once('prop', this.name)) console.log(`[PROP] ${this.name} = ${val}`);
      }
    });
    console.log('[*] hooked __system_property_get');
  }
} catch (e) { console.log('prop hook err ' + e); }

// 2) file opens -> reveals /proc /sys /dev probes used for VM/emulator detection
function hookOpen(name) {
  const p = Module.findExportByName('libc.so', name);
  if (!p) return;
  Interceptor.attach(p, {
    onEnter(args) {
      const idx = name === 'openat' ? 1 : 0;
      try {
        const path = args[idx].readCString();
        if (path && (path.startsWith('/proc') || path.startsWith('/sys') ||
                     path.startsWith('/dev') || path.indexOf('cpuinfo') >= 0 ||
                     path.indexOf('build.prop') >= 0 || path.indexOf('magisk') >= 0 ||
                     path.indexOf('/data/adb') >= 0)) {
          if (once('open', path)) console.log(`[OPEN] ${path}`);
        }
      } catch (e) {}
    }
  });
  console.log('[*] hooked ' + name);
}
['open', 'openat'].forEach(hookOpen);

// 3) java SystemProperties.get + Build access (best-effort)
Java.perform(function () {
  try {
    const SP = Java.use('android.os.SystemProperties');
    SP.get.overload('java.lang.String').implementation = function (k) {
      const v = this.get(k);
      if (once('jprop', k)) console.log(`[JPROP] ${k} = ${v}`);
      return v;
    };
  } catch (e) {}
  console.log('[*] java hooks installed');
});
console.log('[*] DroidGuard tracer ready');
