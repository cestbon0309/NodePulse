#ifndef NP_UPSTREAM_H
#define NP_UPSTREAM_H
#include <sys/wait.h>
#define UPSTREAM_ADDRESSES 8
typedef struct { struct sockaddr_storage address; socklen_t length; } UpstreamAddress;
typedef struct { unsigned count; UpstreamAddress entries[UPSTREAM_ADDRESSES]; } UpstreamAddresses;
static UpstreamAddresses upstream_addresses, upstream_result;
static unsigned upstream_generation, publish_next;
static int upstream_fd = -1, upstream_needed = 1;
static pid_t upstream_pid;
static size_t upstream_have;
static double upstream_next, upstream_deadline;
static void upstream_failed(void) { upstream_needed = 1; }
static int upstream_address_equal(const UpstreamAddress *a, const UpstreamAddress *b) {
  if (a->length != b->length || a->address.ss_family != b->address.ss_family) return 0;
  if (a->address.ss_family == AF_INET) {
    const struct sockaddr_in *x = (const struct sockaddr_in *)&a->address, *y = (const struct sockaddr_in *)&b->address;
    return x->sin_port == y->sin_port && x->sin_addr.s_addr == y->sin_addr.s_addr;
  }
  const struct sockaddr_in6 *x = (const struct sockaddr_in6 *)&a->address, *y = (const struct sockaddr_in6 *)&b->address;
  return x->sin6_port == y->sin6_port && x->sin6_scope_id == y->sin6_scope_id && IN6_ARE_ADDR_EQUAL(&x->sin6_addr, &y->sin6_addr);
}
static void upstream_shutdown(void) {
  if (upstream_pid > 0) {
    kill(upstream_pid, SIGKILL);
    pid_t result = waitpid(upstream_pid, NULL, WNOHANG);
    if (result == upstream_pid || (result < 0 && errno == ECHILD)) upstream_pid = 0;
  }
  if (upstream_fd >= 0) { close(upstream_fd); upstream_fd = -1; }
}
static void upstream_tick(double now, const char *name) {
  if (!name) return;
  if (upstream_pid > 0 && upstream_fd < 0) {
    pid_t result = waitpid(upstream_pid, NULL, WNOHANG);
    if (result == upstream_pid || (result < 0 && errno == ECHILD)) upstream_pid = 0;
    else return;
  }
  if (upstream_fd >= 0) {
    ssize_t n = read(upstream_fd, (char *)&upstream_result + upstream_have, sizeof(upstream_result) - upstream_have);
    if (n > 0) upstream_have += (size_t)n;
    if (upstream_have == sizeof(upstream_result)) {
      if (upstream_result.count && upstream_result.count <= UPSTREAM_ADDRESSES) {
        unsigned next = 0;
        if (upstream_addresses.count) {
          const UpstreamAddress *selected = &upstream_addresses.entries[publish_next % upstream_addresses.count];
          for (unsigned i = 0; i < upstream_result.count; i++)
            if (upstream_address_equal(selected, &upstream_result.entries[i])) { next = i; break; }
        }
        publish_next = next;
        upstream_addresses = upstream_result; upstream_generation++; upstream_needed = 0;
      } else upstream_failed();
      upstream_shutdown();
    } else if (!n || (n < 0 && errno != EAGAIN && errno != EINTR) || now >= upstream_deadline) {
      upstream_shutdown(); upstream_failed();
    }
  }
  if (upstream_pid > 0 || upstream_fd >= 0 || !upstream_needed || now < upstream_next) return;
  upstream_next = now + 30;
  int fds[2];
  if (pipe(fds)) return;
  upstream_pid = fork();
  if (!upstream_pid) {
    signal(SIGALRM, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL);
    alarm(5);
    if (dup2(fds[1], STDOUT_FILENO) < 0) _exit(1);
    long maxfd = sysconf(_SC_OPEN_MAX);
    for (int fd = 3; fd < maxfd; fd++) close(fd);
    UpstreamAddresses result = {0}; struct addrinfo *addresses = NULL;
    if (!endpoint_addresses(name, "127.0.0.1", 0, &addresses)) {
      for (struct addrinfo *a = addresses; a && result.count < UPSTREAM_ADDRESSES; a = a->ai_next) {
        if ((a->ai_family != AF_INET && a->ai_family != AF_INET6) || a->ai_addrlen > sizeof(struct sockaddr_storage)) continue;
        UpstreamAddress *entry = &result.entries[result.count++];
        entry->length = a->ai_addrlen; memcpy(&entry->address, a->ai_addr, a->ai_addrlen);
      }
      freeaddrinfo(addresses);
    }
    size_t sent = 0;
    while (sent < sizeof(result)) {
      ssize_t n = write(STDOUT_FILENO, (char *)&result + sent, sizeof(result) - sent);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) break;
      sent += (size_t)n;
    }
    _exit(0);
  }
  close(fds[1]);
  if (upstream_pid < 0) { upstream_pid = 0; close(fds[0]); return; }
  upstream_fd = fds[0]; upstream_have = 0; upstream_deadline = now + 6;
  fcntl(upstream_fd, F_SETFL, O_NONBLOCK); fcntl(upstream_fd, F_SETFD, FD_CLOEXEC);
}
static int upstream_socket(const UpstreamAddress *address) {
  int fd = socket(address->address.ss_family, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  fcntl(fd, F_SETFL, O_NONBLOCK); fcntl(fd, F_SETFD, FD_CLOEXEC);
  if (connect(fd, (const struct sockaddr *)&address->address, address->length) && errno != EINPROGRESS) {
    close(fd); return -1;
  }
  return fd;
}
#endif
