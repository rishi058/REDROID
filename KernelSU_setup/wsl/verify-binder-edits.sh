#!/usr/bin/env bash
# Confirm every Phase 7 Binder edit landed exactly once and nothing duplicated.
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
SOURCE_DIR="$BUILD_ROOT/linux-6.8.0"
cd "$SOURCE_DIR"

check_once() {
  local file=$1 pattern=$2 want=${3:-1} got
  got=$(grep -cF "$pattern" "$file" || true)
  printf '%-34s %-52s want=%s got=%s\n' "$file" "$pattern" "$want" "$got"
  test "$got" -eq "$want"
}

check_once kernel/sched/wait.c 'EXPORT_SYMBOL_GPL(__wake_up_pollfree);'
check_once kernel/sched/core.c 'EXPORT_SYMBOL(can_nice);'
check_once kernel/task_work.c 'EXPORT_SYMBOL(task_work_add);'
check_once fs/file.c 'EXPORT_SYMBOL(file_close_fd);'
check_once ipc/namespace.c 'EXPORT_SYMBOL(put_ipc_ns);'
check_once ipc/namespace.c 'EXPORT_SYMBOL(show_init_ipc_ns);'
check_once include/linux/ipc_namespace.h 'extern struct ipc_namespace *show_init_ipc_ns(void);'
check_once mm/memory.c 'EXPORT_SYMBOL(zap_page_range_single);'
check_once security/security.c 'EXPORT_SYMBOL(security_binder_set_context_mgr);'
check_once security/security.c 'EXPORT_SYMBOL(security_binder_transaction);'
check_once security/security.c 'EXPORT_SYMBOL(security_binder_transfer_binder);'
check_once security/security.c 'EXPORT_SYMBOL(security_binder_transfer_file);'

check_once drivers/android/binder.c 'module_init(binder_init);'
check_once drivers/android/binder.c 'device_initcall(binder_init);' 0
check_once drivers/android/binder.c 'MODULE_DESCRIPTION("Driver for Android binder device");'
check_once drivers/android/binder_alloc.c 'module_param_named(alloc_debug_mask, binder_alloc_debug_mask, uint, 0644);'
check_once drivers/android/binderfs.c 'show_init_ipc_ns()' 2
check_once drivers/android/binderfs.c '&init_ipc_ns' 0
check_once drivers/android/Kconfig 'depends on (ANDROID_BINDER_IPC=y) || (ANDROID_BINDER_IPC=m && m)'
check_once drivers/android/Makefile 'binder_linux-$(CONFIG_ANDROID_BINDER_IPC_SELFTEST) += binder_alloc_selftest.o'

echo ALL_BINDER_EDITS_VERIFIED
