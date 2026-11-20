#include <sys/types.h>
pid_t reader_spawn(const char *shell, const char *directory, int rows, int cols, int *master);
void reader_resize(int fd, int rows, int cols);
void reader_hangup(int fd, pid_t shell);
