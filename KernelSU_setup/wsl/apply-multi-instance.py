#!/usr/bin/env python3
"""Rewrite pinned KernelSU Next ksud_integration.c into the multi-instance
boot-lifecycle candidate.

The pinned upstream code assumes exactly one Android userspace per host boot. It
keeps `first_zygote` and `init_second_stage_executed` as host-global one-shot
flags, unregisters its own exec hook after the first zygote, and appends the
KernelSU init RC through a single global proxy with global cursors. Under two
ReDroid containers the first Android to boot consumes the whole lifecycle and the
second gets no KernelSU RC actions, so Zygisk and LSPosed never start there.

This script replaces that with:

- per-Android-instance boot records keyed by PID namespace, so `post-fs-data`
  runs once per Android boot per container rather than once per host boot;
- per-open-file init-RC state, so concurrent boots cannot share a cursor;
- module RC loaded from the calling instance's own mount namespace;
- hooks left registered so later instances are still reachable.

Deliberately NOT changed: KernelSU manager identity and the UID allowlist remain
host-global. This is a boot-lifecycle patch, not a multi-tenant root-security
boundary. See ../README.md requirement 6.

Not idempotent by design. A second run fails with "expected one match, found 0"
rather than corrupting the file; start from a fresh tree instead. All edits are
staged in memory and written once, so a failure leaves the file untouched.
"""
from pathlib import Path


SOURCE = Path("/home/builder/kbuild/linux-6.8.0/KernelSU-Next")
TARGET = SOURCE / "kernel/runtime/ksud_integration.c"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


text = TARGET.read_text(encoding="utf-8")

text = replace_once(
    text,
    '#include <linux/namei.h>\n#include <linux/workqueue.h>\n',
    '#include <linux/namei.h>\n'
    '#include <linux/list.h>\n'
    '#include <linux/mutex.h>\n'
    '#include <linux/pid_namespace.h>\n'
    '#include <linux/refcount.h>\n'
    '#include <linux/workqueue.h>\n',
    "headers",
)

text = replace_once(
    text,
    'static void stop_init_rc_hook();\nstatic void stop_execve_hook();\n',
    'static void stop_init_rc_hook();\n',
    "unused declaration",
)

old_exec = r'''void ksu_handle_execveat_ksud(const char *path, struct user_arg_ptr *argv)
{
    static const char app_process[] = "/system/bin/app_process";
    static bool first_zygote = true;

    /* This applies to versions Android 10+ */
    static const char system_bin_init[] = "/system/bin/init";
    static bool init_second_stage_executed = false;

    // https://cs.android.com/android/platform/superproject/+/android-16.0.0_r2:system/core/init/main.cpp;l=77
    if (unlikely(!memcmp(path, system_bin_init, sizeof(system_bin_init) - 1) && argv)) {
        char buf[16];
        if (!init_second_stage_executed && check_argv(*argv, 1, "second_stage", buf, sizeof(buf))) {
            pr_info("/system/bin/init second_stage executed\n");
            ksu_selinux_hide_handle_second_stage();
            apply_kernelsu_rules();
            cache_sid();
            setup_ksu_cred();
            init_second_stage_executed = true;
        }
    }

    if (unlikely(first_zygote && !memcmp(path, app_process, sizeof(app_process) - 1) && argv)) {
        char buf[16];
        if (check_argv(*argv, 1, "-Xzygote", buf, sizeof(buf))) {
            pr_info("exec zygote, /data prepared, second_stage: %d\n", init_second_stage_executed);
            on_post_fs_data();
            first_zygote = false;
            ksu_stop_ksud_execve_hook();
        }
    }
}
'''

new_exec = r'''static DEFINE_MUTEX(android_init_lock);
static bool global_android_init_done;

static bool is_current_namespace_init(void)
{
    struct pid_namespace *pid_ns = task_active_pid_ns(current);

    return pid_ns && task_pid_nr_ns(current, pid_ns) == 1;
}

/*
 * Per-Android-instance boot lifecycle records.
 *
 * Every ReDroid container runs in its own PID namespace, so that namespace is
 * the instance identity. A record is created or reset when a container's init
 * reaches second_stage, and is consumed by the first zygote exec that follows.
 * post-fs-data therefore runs exactly once per Android boot per container,
 * rather than once per host boot (pinned upstream) or once per zygote exec
 * (which would repeat the stage every time Android restarts a dead zygote).
 *
 * A record pins its namespace with get_pid_ns(), so the pointer stays valid and
 * its inode number cannot be recycled underneath us. Any live task in a
 * namespace holds a reference of its own through its nsproxy, so once a
 * container is gone this record is the only remaining holder: a refcount of one
 * is a safe "instance has been removed" predicate, and never true for a
 * namespace that still has tasks.
 */
#define KSU_MAX_ANDROID_INSTANCES 16

struct ksu_android_instance {
    struct list_head node;
    struct pid_namespace *pid_ns;
    bool post_fs_data_done;
};

static LIST_HEAD(ksu_android_instances);
static DEFINE_MUTEX(ksu_android_instances_lock);
static unsigned int ksu_android_instance_count;

/* Caller holds ksu_android_instances_lock. */
static void ksu_reap_dead_instances(void)
{
    struct ksu_android_instance *instance, *tmp;

    list_for_each_entry_safe(instance, tmp, &ksu_android_instances, node) {
        if (refcount_read(&instance->pid_ns->ns.count) != 1)
            continue;
        pr_info("android instance pidns=%u removed, dropping record\n",
                instance->pid_ns->ns.inum);
        list_del(&instance->node);
        put_pid_ns(instance->pid_ns);
        kfree(instance);
        ksu_android_instance_count--;
    }
}

/* Caller holds ksu_android_instances_lock. Returns NULL if untrackable. */
static struct ksu_android_instance *ksu_instance_locked(struct pid_namespace *pid_ns)
{
    struct ksu_android_instance *instance;

    list_for_each_entry(instance, &ksu_android_instances, node) {
        if (instance->pid_ns == pid_ns)
            return instance;
    }

    ksu_reap_dead_instances();
    if (ksu_android_instance_count >= KSU_MAX_ANDROID_INSTANCES) {
        pr_warn("android instance table full (%u), pidns=%u untracked\n",
                ksu_android_instance_count, pid_ns->ns.inum);
        return NULL;
    }

    instance = kzalloc(sizeof(*instance), GFP_KERNEL);
    if (!instance) {
        pr_warn("android instance record allocation failed for pidns=%u\n",
                pid_ns->ns.inum);
        return NULL;
    }

    instance->pid_ns = get_pid_ns(pid_ns);
    list_add(&instance->node, &ksu_android_instances);
    ksu_android_instance_count++;
    pr_info("android instance pidns=%u registered (%u tracked)\n",
            pid_ns->ns.inum, ksu_android_instance_count);
    return instance;
}

/* A fresh Android boot in this namespace re-arms its post-fs-data stage. */
static void ksu_mark_instance_booting(struct pid_namespace *pid_ns)
{
    struct ksu_android_instance *instance;

    if (!pid_ns)
        return;

    mutex_lock(&ksu_android_instances_lock);
    instance = ksu_instance_locked(pid_ns);
    if (instance)
        instance->post_fs_data_done = false;
    mutex_unlock(&ksu_android_instances_lock);
}

/*
 * True when this caller should run post-fs-data for its namespace.
 *
 * Fails open. An untrackable namespace behaves like the pinned upstream code and
 * runs the stage, because wrongly skipping it leaves that instance with no
 * KernelSU at all, while wrongly repeating it is what upstream already tolerated.
 */
static bool ksu_claim_post_fs_data(struct pid_namespace *pid_ns)
{
    struct ksu_android_instance *instance;
    bool claimed = true;

    if (!pid_ns)
        return true;

    mutex_lock(&ksu_android_instances_lock);
    instance = ksu_instance_locked(pid_ns);
    if (instance) {
        claimed = !instance->post_fs_data_done;
        instance->post_fs_data_done = true;
    }
    mutex_unlock(&ksu_android_instances_lock);
    return claimed;
}

void ksu_handle_execveat_ksud(const char *path, struct user_arg_ptr *argv)
{
    static const char app_process[] = "/system/bin/app_process";
    static const char system_bin_init[] = "/system/bin/init";
    struct pid_namespace *pid_ns;
    char buf[16];

    /*
     * Android containers have separate PID and mount namespaces but share this
     * host kernel. Keep global SELinux/credential setup one-shot, while leaving
     * the exec hook active so every Android namespace can reach zygote.
     */
    if (unlikely(argv && !strcmp(path, system_bin_init) &&
                 is_current_namespace_init() &&
                 check_argv(*argv, 1, "second_stage", buf, sizeof(buf)))) {
        pid_ns = task_active_pid_ns(current);
        mutex_lock(&android_init_lock);
        if (!global_android_init_done) {
            pr_info("first Android init second_stage (pidns=%u), applying global KernelSU setup\n",
                    pid_ns ? pid_ns->ns.inum : 0);
            ksu_selinux_hide_handle_second_stage();
            apply_kernelsu_rules();
            cache_sid();
            setup_ksu_cred();
            global_android_init_done = true;
        } else {
            pr_info("additional Android init second_stage (pidns=%u)\n",
                    pid_ns ? pid_ns->ns.inum : 0);
        }
        mutex_unlock(&android_init_lock);
        ksu_mark_instance_booting(pid_ns);
    }

    if (unlikely(argv && !strcmp(path, app_process) &&
                 check_argv(*argv, 1, "-Xzygote", buf, sizeof(buf)))) {
        pid_ns = task_active_pid_ns(current);
        if (ksu_claim_post_fs_data(pid_ns)) {
            pr_info("Android zygote exec (pidns=%u), running post-fs-data\n",
                    pid_ns ? pid_ns->ns.inum : 0);
            on_post_fs_data();
        } else {
            pr_info("Android zygote exec (pidns=%u), post-fs-data already done\n",
                    pid_ns ? pid_ns->ns.inum : 0);
        }
    }
}
'''

text = replace_once(text, old_exec, new_exec, "exec lifecycle")

start = text.index("static ssize_t (*orig_read)")
end = text.index("static void ksu_handle_sys_read", start)

new_proxy = r'''struct ksu_rc_file {
    struct file_operations fops;
    const struct file_operations *orig_fops;
    struct mutex lock;
    char *module_rc;
    size_t module_rc_len;
    size_t static_pos;
    size_t module_pos;
};

const size_t ksu_rc_len = sizeof(KERNEL_SU_RC) - 1;

// Prefer /metadata/watchdog/ when present, else /metadata.
#define MODULE_RC_PATH_WATCHDOG "/metadata/watchdog/ksu/modules.rc"
#define MODULE_RC_PATH_DEFAULT "/metadata/ksu/modules.rc"

static struct file *open_module_rc(const char **chosen_path)
{
    struct file *f = filp_open(MODULE_RC_PATH_WATCHDOG, O_RDONLY, 0);

    if (!IS_ERR(f)) {
        *chosen_path = MODULE_RC_PATH_WATCHDOG;
        return f;
    }
    f = filp_open(MODULE_RC_PATH_DEFAULT, O_RDONLY, 0);
    if (!IS_ERR(f)) {
        *chosen_path = MODULE_RC_PATH_DEFAULT;
        return f;
    }
    *chosen_path = MODULE_RC_PATH_DEFAULT;
    return f;
}

/*
 * ksu_cred is set by setup_ksu_cred() during the first Android init second_stage,
 * which normally precedes any init.rc read. It is not guaranteed: if check_argv
 * never matches, if an instance's init is not PID 1 in its own namespace, or if
 * credential setup failed, this runs first and override_creds(NULL) would
 * dereference NULL in the kernel. Skip the module RC instead.
 */
static size_t get_module_rc_size(void)
{
    const struct cred *old_cred;
    const char *path = NULL;
    struct file *f;
    size_t size = 0;

    if (ksu_no_custom_rc || !ksu_cred)
        return 0;

    old_cred = override_creds(ksu_cred);
    f = open_module_rc(&path);
    if (!IS_ERR(f)) {
        if (S_ISREG(file_inode(f)->i_mode))
            size = i_size_read(file_inode(f));
        filp_close(f, NULL);
    }
    revert_creds(old_cred);
    return size;
}

static void load_module_rc(struct ksu_rc_file *proxy)
{
    const struct cred *old_cred;
    const char *path = NULL;
    struct file *f;
    loff_t pos = 0;
    ssize_t result;
    size_t size;

    /* See get_module_rc_size(): ksu_cred may not be set up yet. */
    if (ksu_no_custom_rc || !ksu_cred)
        return;

    old_cred = override_creds(ksu_cred);
    f = open_module_rc(&path);
    if (IS_ERR(f))
        goto out_revert;
    if (!S_ISREG(file_inode(f)->i_mode))
        goto out_close;

    size = i_size_read(file_inode(f));
    if (!size)
        goto out_close;
    proxy->module_rc = kvmalloc(size, GFP_KERNEL);
    if (!proxy->module_rc)
        goto out_close;

    result = kernel_read(f, proxy->module_rc, size, &pos);
    if (result <= 0) {
        kvfree(proxy->module_rc);
        proxy->module_rc = NULL;
        goto out_close;
    }
    proxy->module_rc_len = result;
    pr_info("module rc: loaded %zu bytes from %s for Android init\n",
            proxy->module_rc_len, path);

out_close:
    filp_close(f, NULL);
out_revert:
    revert_creds(old_cred);
}

static ssize_t read_proxy(struct file *file, char __user *buf, size_t count,
                          loff_t *pos)
{
    struct ksu_rc_file *proxy =
        container_of(file->f_op, struct ksu_rc_file, fops);
    ssize_t ret;
    size_t append_count;

    mutex_lock(&proxy->lock);
    ret = proxy->orig_fops->read(file, buf, count, pos);
    if (ret != 0)
        goto out;

    if (proxy->static_pos < ksu_rc_len) {
        append_count = min_t(size_t, ksu_rc_len - proxy->static_pos, count);
        if (copy_to_user(buf, KERNEL_SU_RC + proxy->static_pos, append_count))
            goto out;
        proxy->static_pos += append_count;
        ret += append_count;
    }

    if (proxy->static_pos == ksu_rc_len &&
        proxy->module_pos < proxy->module_rc_len && (size_t)ret < count) {
        append_count = min_t(size_t,
                             proxy->module_rc_len - proxy->module_pos,
                             count - ret);
        if (copy_to_user(buf + ret, proxy->module_rc + proxy->module_pos,
                         append_count))
            goto out;
        proxy->module_pos += append_count;
        ret += append_count;
    }

out:
    mutex_unlock(&proxy->lock);
    return ret;
}

static ssize_t read_iter_proxy(struct kiocb *iocb, struct iov_iter *to)
{
    struct file *file = iocb->ki_filp;
    struct ksu_rc_file *proxy =
        container_of(file->f_op, struct ksu_rc_file, fops);
    ssize_t ret;
    size_t append_count;

    mutex_lock(&proxy->lock);
    ret = proxy->orig_fops->read_iter(iocb, to);
    if (ret != 0)
        goto out;

    if (proxy->static_pos < ksu_rc_len) {
        append_count = copy_to_iter(KERNEL_SU_RC + proxy->static_pos,
                                    ksu_rc_len - proxy->static_pos, to);
        proxy->static_pos += append_count;
        ret += append_count;
    }

    if (proxy->static_pos == ksu_rc_len &&
        proxy->module_pos < proxy->module_rc_len) {
        append_count = copy_to_iter(proxy->module_rc + proxy->module_pos,
                                    proxy->module_rc_len - proxy->module_pos,
                                    to);
        proxy->module_pos += append_count;
        ret += append_count;
    }

out:
    mutex_unlock(&proxy->lock);
    return ret;
}

static int release_proxy(struct inode *inode, struct file *file)
{
    struct ksu_rc_file *proxy =
        container_of(file->f_op, struct ksu_rc_file, fops);
    const struct file_operations *orig_fops = proxy->orig_fops;
    int ret = 0;

    /* __fput() uses file->f_op after ->release(), so restore it first. */
    WRITE_ONCE(file->f_op, orig_fops);
    if (orig_fops->release)
        ret = orig_fops->release(inode, file);
    kvfree(proxy->module_rc);
    kfree(proxy);
    return ret;
}

static bool is_init_rc(struct file *file)
{
    const char *short_name;
    char path[256];
    char *resolved;

    if (strcmp(current->comm, "init") || !is_current_namespace_init())
        return false;
    if (!d_is_reg(file->f_path.dentry))
        return false;
    short_name = file->f_path.dentry->d_name.name;
    if (strcmp(short_name, "init.rc"))
        return false;
    resolved = d_path(&file->f_path, path, sizeof(path));
    return !IS_ERR(resolved) &&
           !strcmp(resolved, "/system/etc/init/hw/init.rc");
}

static void ksu_install_rc_hook(struct file *file)
{
    struct ksu_rc_file *proxy;

    if (!is_init_rc(file))
        return;
    if (file->f_op->read == read_proxy ||
        file->f_op->read_iter == read_iter_proxy)
        return;

    proxy = kzalloc(sizeof(*proxy), GFP_KERNEL);
    if (!proxy)
        return;
    proxy->orig_fops = file->f_op;
    memcpy(&proxy->fops, file->f_op, sizeof(proxy->fops));
    mutex_init(&proxy->lock);
    load_module_rc(proxy);

    if (proxy->orig_fops->read)
        proxy->fops.read = read_proxy;
    if (proxy->orig_fops->read_iter)
        proxy->fops.read_iter = read_iter_proxy;
    proxy->fops.release = release_proxy;
    WRITE_ONCE(file->f_op, &proxy->fops);
    pr_info("attached independent KernelSU rc stream to Android init\n");
}

'''

text = text[:start] + new_proxy + text[end:]

old_fstat = r'''        if (is_init_rc(file)) {
            pr_info("stat init.rc");
            is_rc = true;
            load_module_rc_once();
        }
'''
new_fstat = r'''        if (is_init_rc(file)) {
            pr_info("stat init.rc for Android namespace");
            is_rc = true;
        }
'''
text = replace_once(text, old_fstat, new_fstat, "fstat detection")

text = replace_once(
    text,
    "        size_t extra = ksu_rc_len + module_rc_len;\n",
    "        size_t extra = ksu_rc_len + get_module_rc_size();\n",
    "fstat size",
)

text = replace_once(
    text,
    "            pr_info(\"adding rc len: %ld -> %ld (static=%zu module=%zu)\", size, new_size, ksu_rc_len, module_rc_len);\n",
    "            pr_info(\"adding rc len: %ld -> %ld (static=%zu module=%zu)\",\n"
    "                    size, new_size, ksu_rc_len, extra - ksu_rc_len);\n",
    "fstat log",
)

old_exit = r'''void __exit ksu_ksud_exit()
{
    // TODO:
    // this should be done before unregister vfs_read_kp
    // stop_init_rc_hook();
    unregister_kprobe(&input_event_kp);

    if (module_rc_buf) {
        free_module_rc();
    }
}
'''
new_exit = r'''void __exit ksu_ksud_exit()
{
    stop_init_rc_hook();
    unregister_kprobe(&input_event_kp);
}
'''
text = replace_once(text, old_exit, new_exit, "ksud exit")

TARGET.write_text(text, encoding="utf-8")
print(TARGET)
