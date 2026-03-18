#include <sys/ioctl.h> // ioctl and constants
#include <sys/ttycom.h>  // ioctl and constants for TIOCPTYGNAME
#include <sys/types.h>
#include <unistd.h> // tcgetpgrp
#include <util.h> // openpty

#ifndef TIOCSCTTY
#define TIOCSCTTY 536900705
#endif

#ifndef TIOCSWINSZ
#define TIOCSWINSZ 2148037735
#endif

#ifndef TIOCGWINSZ
#define TIOCGWINSZ 1074295912
#endif
