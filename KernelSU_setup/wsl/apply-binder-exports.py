#!/usr/bin/env python3
"""Add the core-kernel symbol exports that a loadable Binder module requires.

`binder_linux.ko` references eleven symbols that vanilla v6.8.12 keeps internal.
Ubuntu's 6.8.0-138 tree exports every one of them, which is why the deleted
`linux-upstream` tree linked and this reconstruction did not. Each edit below
mirrors Ubuntu's export type and placement exactly.

The list is the complete set. It was derived by comparing the undefined symbols
of the already linked drivers/android/binder_linux.o against the
`.export_symbol` entries of vmlinux.o, not from modpost's truncated ten-line
report:

    aarch64-linux-gnu-nm -u drivers/android/binder_linux.o | sed -n 's/.*U //p'
    aarch64-linux-gnu-nm vmlinux.o | sed -n 's/.*__export_symbol_//p'

`init_ipc_ns` is a data symbol, so Ubuntu does not export it. It adds a
`show_init_ipc_ns()` accessor and BinderFS calls that instead. Ubuntu also adds
a `get_ipc_ns_exported()` wrapper; modpost never asks for it, so it is left out.
Nothing here changes behaviour: these edits only widen symbol visibility.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from binder_edit import EditSet  # noqa: E402

edits = EditSet(Path("/home/builder/kbuild/linux-6.8.0"))


def export_after(rel: str, body: str, symbol: str, macro: str = "EXPORT_SYMBOL") -> None:
    edits.replace(rel, body, f"{body}{macro}({symbol});\n", symbol)


# kernel/sched/wait.c :: __wake_up_pollfree
export_after(
    "kernel/sched/wait.c",
    'void __wake_up_pollfree(struct wait_queue_head *wq_head)\n'
    '{\n'
    '\t__wake_up(wq_head, TASK_NORMAL, 0, poll_to_key(EPOLLHUP | POLLFREE));\n'
    '\t/* POLLFREE must have cleared the queue. */\n'
    '\tWARN_ON_ONCE(waitqueue_active(wq_head));\n'
    '}\n',
    "__wake_up_pollfree",
    macro="EXPORT_SYMBOL_GPL",
)

# kernel/sched/core.c :: can_nice
export_after(
    "kernel/sched/core.c",
    'int can_nice(const struct task_struct *p, const int nice)\n'
    '{\n'
    '\treturn is_nice_reduction(p, nice) || capable(CAP_SYS_NICE);\n'
    '}\n',
    "can_nice",
)

# kernel/task_work.c :: task_work_add. Anchored on the following kernel-doc
# block because a bare `return 0; }` is not unique in this file.
edits.replace(
    "kernel/task_work.c",
    '\treturn 0;\n'
    '}\n'
    '\n'
    '/**\n'
    ' * task_work_cancel_match - cancel a pending work added by task_work_add()\n',
    '\treturn 0;\n'
    '}\n'
    'EXPORT_SYMBOL(task_work_add);\n'
    '\n'
    '/**\n'
    ' * task_work_cancel_match - cancel a pending work added by task_work_add()\n',
    "task_work_add",
)

# fs/file.c :: file_close_fd
export_after(
    "fs/file.c",
    'struct file *file_close_fd(unsigned int fd)\n'
    '{\n'
    '\tstruct files_struct *files = current->files;\n'
    '\tstruct file *file;\n'
    '\n'
    '\tspin_lock(&files->file_lock);\n'
    '\tfile = file_close_fd_locked(files, fd);\n'
    '\tspin_unlock(&files->file_lock);\n'
    '\n'
    '\treturn file;\n'
    '}\n',
    "file_close_fd",
)

# ipc/namespace.c :: put_ipc_ns, plus the accessor that replaces init_ipc_ns.
edits.replace(
    "ipc/namespace.c",
    'void put_ipc_ns(struct ipc_namespace *ns)\n'
    '{\n'
    '\tif (refcount_dec_and_lock(&ns->ns.count, &mq_lock)) {\n'
    '\t\tmq_clear_sbinfo(ns);\n'
    '\t\tspin_unlock(&mq_lock);\n'
    '\n'
    '\t\tif (llist_add(&ns->mnt_llist, &free_ipc_list))\n'
    '\t\t\tschedule_work(&free_ipc_work);\n'
    '\t}\n'
    '}\n',
    'void put_ipc_ns(struct ipc_namespace *ns)\n'
    '{\n'
    '\tif (refcount_dec_and_lock(&ns->ns.count, &mq_lock)) {\n'
    '\t\tmq_clear_sbinfo(ns);\n'
    '\t\tspin_unlock(&mq_lock);\n'
    '\n'
    '\t\tif (llist_add(&ns->mnt_llist, &free_ipc_list))\n'
    '\t\t\tschedule_work(&free_ipc_work);\n'
    '\t}\n'
    '}\n'
    'EXPORT_SYMBOL(put_ipc_ns);\n'
    '\n'
    'struct ipc_namespace *show_init_ipc_ns(void)\n'
    '{\n'
    '#if defined(CONFIG_IPC_NS)\n'
    '\treturn &init_ipc_ns;\n'
    '#else\n'
    '\treturn NULL;\n'
    '#endif\n'
    '}\n'
    'EXPORT_SYMBOL(show_init_ipc_ns);\n',
    "put_ipc_ns and show_init_ipc_ns",
)

# include/linux/ipc_namespace.h :: declare the accessor.
edits.replace(
    "include/linux/ipc_namespace.h",
    'static inline int mq_init_ns(struct ipc_namespace *ns) { return 0; }\n'
    '#endif\n'
    '\n'
    '#if defined(CONFIG_IPC_NS)\n',
    'static inline int mq_init_ns(struct ipc_namespace *ns) { return 0; }\n'
    '#endif\n'
    '\n'
    'extern struct ipc_namespace *show_init_ipc_ns(void);\n'
    '\n'
    '#if defined(CONFIG_IPC_NS)\n',
    "show_init_ipc_ns declaration",
)

# mm/memory.c :: zap_page_range_single
export_after(
    "mm/memory.c",
    '\tunmap_single_vma(&tlb, vma, address, end, details, false);\n'
    '\tmmu_notifier_invalidate_range_end(&range);\n'
    '\ttlb_finish_mmu(&tlb);\n'
    '\thugetlb_zap_end(vma, details);\n'
    '}\n',
    "zap_page_range_single",
)

# security/security.c :: the four Binder LSM hook wrappers.
for symbol, signature, call in (
    (
        "security_binder_set_context_mgr",
        'int security_binder_set_context_mgr(const struct cred *mgr)\n',
        '\treturn call_int_hook(binder_set_context_mgr, 0, mgr);\n',
    ),
    (
        "security_binder_transaction",
        'int security_binder_transaction(const struct cred *from,\n'
        '\t\t\t\tconst struct cred *to)\n',
        '\treturn call_int_hook(binder_transaction, 0, from, to);\n',
    ),
    (
        "security_binder_transfer_binder",
        'int security_binder_transfer_binder(const struct cred *from,\n'
        '\t\t\t\t    const struct cred *to)\n',
        '\treturn call_int_hook(binder_transfer_binder, 0, from, to);\n',
    ),
    (
        "security_binder_transfer_file",
        'int security_binder_transfer_file(const struct cred *from,\n'
        '\t\t\t\t  const struct cred *to, const struct file *file)\n',
        '\treturn call_int_hook(binder_transfer_file, 0, from, to, file);\n',
    ),
):
    export_after("security/security.c", f"{signature}{{\n{call}}}\n", symbol)

edits.apply()
print("BINDER_EXPORTS_APPLIED")
