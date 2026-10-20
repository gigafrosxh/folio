#include "FolioTerminal.h"
#include <util.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <signal.h>

// Prepare all Swift/Foundation state before this call. Only async-signal-safe operations run
// in the forked child; forkpty supplies its own session and controlling terminal.
pid_t folio_spawn_terminal(int *master, char *const argv[], char *const envp[], const char *directory, unsigned short columns, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        // Swift worker threads may block signals. Do not pass their mask to the shell.
        sigset_t mask;
        sigemptyset(&mask);
        sigprocmask(SIG_SETMASK, &mask, NULL);
        struct sigaction action = { .sa_handler = SIG_DFL };
        sigemptyset(&action.sa_mask);
        const int signals[] = {SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGPIPE};
        for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i)
            sigaction(signals[i], &action, NULL);
        if (chdir(directory) != 0) _exit(126);
        execve(argv[0], argv, envp);
        _exit(127);
    }
    return pid;
}
