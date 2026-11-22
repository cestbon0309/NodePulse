#ifndef NP_EGRESS_H
#define NP_EGRESS_H
#include <sys/wait.h>

static const char *egress_service = "http://api.ipify.org,http://ifconfig.me/ip,http://icanhazip.com";
#if ADMIN
static int egress_fd = -1, egress_provider;
static pid_t egress_pid;
static double egress_next, egress_deadline;
static unsigned egress_backoff = 60;

static int egress_public(const char *ip) {
  unsigned char a[16];
  if (inet_pton(AF_INET, ip, a) == 1)
    return a[0] && a[0] != 10 && a[0] != 127 && a[0] < 224 &&
      !(a[0] == 100 && (a[1] & 192) == 64) && !(a[0] == 169 && a[1] == 254) &&
      !(a[0] == 172 && (a[1] & 240) == 16) && !(a[0] == 192 && a[1] == 168) &&
      !(a[0] == 192 && a[1] == 0 && (a[2] == 0 || a[2] == 2)) &&
      !(a[0] == 198 && (a[1] == 18 || a[1] == 19 || (a[1] == 51 && a[2] == 100))) &&
      !(a[0] == 203 && a[1] == 0 && a[2] == 113);
  return inet_pton(AF_INET6, ip, a) == 1 && (a[0] & 224) == 32 &&
    !(a[0] == 32 && a[1] == 1 && a[2] == 13 && a[3] == 184);
}

static int egress_url(const char *url, char *authority, char *path) {
  if (strncmp(url, "http://", 7)) return -1;
  const char *host = url + 7, *slash = strchr(host, '/');
  size_t n = slash ? (size_t)(slash - host) : strlen(host);
  if (!n || n >= 256 || strcspn(host, "\r\n\t @#?") < n || (slash && strlen(slash) >= 256)) return -1;
  memcpy(authority, host, n); authority[n] = 0;
  snprintf(path, 256, "%s", slash ? slash : "/");
  return strpbrk(path, "\r\n ") ? -1 : 0;
}

static void egress_fetch(const char *url, int output) {
  char host[256], path[256], address[272], data[2048];
  if (egress_url(url, host, path)) return;
  snprintf(address, sizeof(address), "%s%s", host, strchr(host, ':') ? "" : ":80");
  int fd = endpoint(address, "", 0);
  if (fd < 0) return;
  fcntl(fd, F_SETFL, 0);
  int n = snprintf(data, sizeof(data), "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", path, host);
  size_t sent = 0;
  while (sent < (size_t)n) {
    ssize_t written = write(fd, data + sent, (size_t)n - sent);
    if (written <= 0) { close(fd); return; }
    sent += (size_t)written;
  }
  size_t have = 0;
  ssize_t got;
  while (have < sizeof(data) - 1 && (got = read(fd, data + have, sizeof(data) - 1 - have)) > 0) have += (size_t)got;
  close(fd); data[have] = 0;
  if (strncmp(data, "HTTP/1.0 200 ", 13) && strncmp(data, "HTTP/1.1 200 ", 13)) return;
  char *body = strstr(data, "\r\n\r\n");
  if (!body || strcasestr(data, "transfer-encoding:")) return;
  body += 4;
  while (isspace((unsigned char)*body)) body++;
  char *end = body + strlen(body);
  while (end > body && isspace((unsigned char)end[-1])) *--end = 0;
  if (strlen(body) < INET6_ADDRSTRLEN && egress_public(body)) (void)write(output, body, strlen(body));
}

static void egress_shutdown(void) {
  if (egress_pid > 0) { kill(egress_pid, SIGKILL); while (waitpid(egress_pid, NULL, 0) < 0 && errno == EINTR) {} egress_pid = 0; }
  if (egress_fd >= 0) { close(egress_fd); egress_fd = -1; }
}

static void egress_tick(double now, int enabled) {
  if (!enabled || !strcmp(egress_service, "off")) return;
  if (egress_fd >= 0) {
    char ip[INET6_ADDRSTRLEN] = {0};
    ssize_t n = read(egress_fd, ip, sizeof(ip) - 1);
    if (n < 0 && now < egress_deadline) return;
    egress_shutdown();
    if (n > 0 && egress_public(ip)) {
      snprintf(egress_ip, sizeof(egress_ip), "%s", ip);
      egress_backoff = 60; egress_provider = 0; egress_next = now + 21600;
      return;
    }
    egress_provider++;
    egress_next = now + 1;
  }
  if (now < egress_next) return;
  char urls[1024]; snprintf(urls, sizeof(urls), "%s", egress_service);
  char *save = NULL, *url = strtok_r(urls, ",", &save);
  for (int i = 0; url && i < egress_provider; i++) url = strtok_r(NULL, ",", &save);
  if (!url) {
    egress_provider = 0; egress_next = now + egress_backoff;
    if (egress_backoff < 3600) egress_backoff = egress_backoff > 1800 ? 3600 : egress_backoff * 2;
    return;
  }
  int fds[2];
  if (pipe(fds)) { egress_next = now + 60; return; }
  egress_pid = fork();
  if (!egress_pid) {
    signal(SIGALRM, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL);
    alarm(5);
    close(fds[0]);
    long maxfd = sysconf(_SC_OPEN_MAX);
    for (int fd = 3; fd < maxfd; fd++) if (fd != fds[1]) close(fd);
    egress_fetch(url, fds[1]);
    _exit(0);
  }
  close(fds[1]);
  if (egress_pid < 0) { close(fds[0]); egress_pid = 0; egress_next = now + 60; return; }
  egress_fd = fds[0]; fcntl(egress_fd, F_SETFL, O_NONBLOCK); fcntl(egress_fd, F_SETFD, FD_CLOEXEC);
  egress_deadline = now + 6;
}
#else
static void egress_tick(double now, int enabled) { (void)now; (void)enabled; }
static void egress_shutdown(void) {}
#endif
#endif
