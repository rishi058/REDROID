#!/usr/bin/env python3
"""Complete the Ubuntu-proven modular-Binder delta on the vanilla v6.8.12 tree.

The first reconstruction only made Binder/BinderFS `tristate` and merged the
objects into `binder_linux`. Comparing against Ubuntu 6.8.0-138 showed four
further changes that are required before `binder_linux.ko` behaves like the
module the production kernel shipped:

1. `device_initcall(binder_init)` is inert inside a module, so the module would
   load and silently never create any Binder device. Ubuntu uses `module_init`.
2. Both binder.o and binder_alloc.o define a `debug_mask` module parameter. Once
   they share one KBUILD_MODNAME the two sysfs entries collide, so Ubuntu renames
   the allocator one to `alloc_debug_mask`.
3. A module cannot reference the `init_ipc_ns` data symbol. Ubuntu calls an
   exported `show_init_ipc_ns()` accessor instead.
4. A `tristate` BinderFS must not be selectable as `y` while Binder IPC is `m`.

Only module-enablement changes are taken. Ubuntu's unrelated stable backports
and its newer `lsmcontext` LSM API are deliberately NOT imported: vanilla
v6.8.12 uses the three-argument secctx API that this build already targets.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from binder_edit import EditSet  # noqa: E402

edits = EditSet(Path("/home/builder/kbuild/linux-6.8.0"))

# 1. A tristate BinderFS must follow Binder IPC's tristate state.
edits.replace(
    "drivers/android/Kconfig",
    'config ANDROID_BINDERFS\n'
    '\ttristate "Android Binderfs filesystem"\n'
    '\tdepends on ANDROID_BINDER_IPC\n'
    '\tdefault n\n',
    'config ANDROID_BINDERFS\n'
    '\ttristate "Android Binderfs filesystem"\n'
    '\tdepends on (ANDROID_BINDER_IPC=y) || (ANDROID_BINDER_IPC=m && m)\n'
    '\tdefault n\n',
    "Kconfig tristate dependency",
)

# 2. Keep the selftest object inside the composite module, as Ubuntu does.
edits.replace(
    "drivers/android/Makefile",
    'obj-$(CONFIG_ANDROID_BINDER_IPC)\t+= binder_linux.o\n'
    'binder_linux-y\t\t\t\t:= binder.o binder_alloc.o\n'
    'binder_linux-$(CONFIG_ANDROID_BINDERFS)\t+= binderfs.o\n'
    'obj-$(CONFIG_ANDROID_BINDER_IPC_SELFTEST) += binder_alloc_selftest.o\n',
    'binder_linux-y := binder.o binder_alloc.o\n'
    'obj-$(CONFIG_ANDROID_BINDER_IPC) += binder_linux.o\n'
    'binder_linux-$(CONFIG_ANDROID_BINDERFS) += binderfs.o\n'
    'binder_linux-$(CONFIG_ANDROID_BINDER_IPC_SELFTEST) += binder_alloc_selftest.o\n',
    "Makefile composite module layout",
)

# 3. IS_ENABLED() needs kconfig.h, which Ubuntu includes explicitly.
edits.replace(
    "drivers/android/binder_internal.h",
    '#include <linux/export.h>\n#include <linux/fs.h>\n#include <linux/list.h>\n',
    '#include <linux/export.h>\n#include <linux/fs.h>\n#include <linux/kconfig.h>\n'
    '#include <linux/list.h>\n',
    "binder_internal.h kconfig.h include",
)
edits.replace(
    "drivers/android/binder_alloc.h",
    '#define _LINUX_BINDER_ALLOC_H\n\n#include <linux/rbtree.h>\n',
    '#define _LINUX_BINDER_ALLOC_H\n\n#include <linux/kconfig.h>\n'
    '#include <linux/rbtree.h>\n',
    "binder_alloc.h kconfig.h include",
)
edits.replace(
    "drivers/android/binder_alloc.h",
    '#ifdef CONFIG_ANDROID_BINDER_IPC_SELFTEST\n',
    '#if IS_ENABLED(CONFIG_ANDROID_BINDER_IPC_SELFTEST)\n',
    "binder_alloc.h selftest IS_ENABLED",
)

# 4. Avoid the duplicate `debug_mask` parameter inside one module namespace.
edits.replace(
    "drivers/android/binder_alloc.c",
    'module_param_named(debug_mask, binder_alloc_debug_mask,\n\t\t   uint, 0644);\n',
    'module_param_named(alloc_debug_mask, binder_alloc_debug_mask, uint, 0644);\n',
    "binder_alloc.c module parameter rename",
)

# 5. A module needs module_init, not an inert initcall section entry.
edits.replace(
    "drivers/android/binder.c",
    'device_initcall(binder_init);\n'
    '\n'
    '#define CREATE_TRACE_POINTS\n'
    '#include "binder_trace.h"\n'
    '\n'
    'MODULE_LICENSE("GPL v2");\n',
    'module_init(binder_init);\n'
    '/*\n'
    ' * binder will have no exit function since binderfs instances can be mounted\n'
    ' * multiple times and also in user namespaces finding and destroying them all\n'
    ' * is not feasible without introducing insane locking. Just ignoring existing\n'
    ' * instances on module unload also wouldn\'t work since we would loose track of\n'
    ' * what major numer was dynamically allocated and also what minor numbers are\n'
    ' * already given out. So this would get us into all kinds of issues with device\n'
    ' * number reuse. So simply don\'t allow unloading unless we are forced to do so.\n'
    ' */\n'
    '\n'
    'MODULE_AUTHOR("Google, Inc.");\n'
    'MODULE_DESCRIPTION("Driver for Android binder device");\n'
    'MODULE_LICENSE("GPL v2");\n'
    '\n'
    '#define CREATE_TRACE_POINTS\n'
    '#include "binder_trace.h"\n',
    "binder.c module_init and module metadata",
)

# 6. Reach the initial IPC namespace through the exported accessor.
edits.replace(
    "drivers/android/binderfs.c",
    '\tbool use_reserve = (info->ipc_ns == &init_ipc_ns);\n',
    '\tbool use_reserve = (info->ipc_ns == show_init_ipc_ns());\n',
    "binderfs.c init_ipc_ns accessor",
    count=2,
)

edits.apply()
print("BINDER_MODULE_DELTA_APPLIED")
