#define _GNU_SOURCE // ptsname_r
#include <pty.h> // openpty
#include <stdlib.h> // ptsname_r
#include <sys/ioctl.h> // ioctl and constants
#include <unistd.h> // tcgetpgrp, setsid
