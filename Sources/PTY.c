#include "PTY.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <string.h>
#include <errno.h>

pid_t reader_spawn(const char *shell, const char *directory, int rows, int cols, int *master) {
    struct winsize size = {.ws_row=rows,.ws_col=cols};
    pid_t child = forkpty(master, NULL, NULL, &size);
    if (child == 0) {
        sigset_t mask; sigemptyset(&mask); sigprocmask(SIG_SETMASK, &mask, NULL);
        for (int sig=1; sig<NSIG; sig++) signal(sig, SIG_DFL);
        if (chdir(directory) < 0 && getenv("HOME")) chdir(getenv("HOME"));
        setenv("TERM","xterm-256color",1);
        execl(shell, shell, "-l", (char *)NULL);
        _exit(127);
    }
    if (child > 0) fcntl(*master,F_SETFD,FD_CLOEXEC);
    return child;
}
void reader_resize(int fd, int rows, int cols) {
    struct winsize size={.ws_row=rows,.ws_col=cols};
    ioctl(fd,TIOCSWINSZ,&size);
}
void reader_hangup(int fd, pid_t child) {
    pid_t fg=tcgetpgrp(fd);
    if(fg>0 && fg!=getpgrp()) kill(-fg,SIGHUP);
    if(child>0) kill(child,SIGHUP);
}
