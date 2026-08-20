#include <errno.h>
#include <fcntl.h>
#include <linux/android/binderfs.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    struct binderfs_device device = {0};
    int fd;

    if (argc != 3) {
        fprintf(stderr, "usage: %s BINDER_CONTROL DEVICE_NAME\n", argv[0]);
        return 2;
    }
    if (strlen(argv[2]) >= sizeof(device.name)) {
        fprintf(stderr, "binder device name is too long\n");
        return 2;
    }

    fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        perror("open binder-control");
        return 1;
    }
    strcpy(device.name, argv[2]);
    if (ioctl(fd, BINDER_CTL_ADD, &device) < 0) {
        fprintf(stderr, "BINDER_CTL_ADD %s failed: %s\n", argv[2], strerror(errno));
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}
