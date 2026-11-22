#ifndef NP_METRICS_H
#define NP_METRICS_H
#include "vendor/monocypher-ed25519.h"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
typedef struct {
  char *s;
  size_t n, cap;
} Buffer;
static void add(Buffer *b, const char *fmt, ...) {
  for (;;) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b->s + b->n, b->cap - b->n, fmt, ap);
    va_end(ap);
    if (n < 0)
      abort();
    if ((size_t)n < b->cap - b->n) {
      b->n += (size_t)n;
      return;
    }
    b->cap = (b->cap + (size_t)n + 1) * 2;
    char *p = realloc(b->s, b->cap);
    if (!p)
      abort();
    b->s = p;
  }
}
static Buffer buffer(void) {
  Buffer b = {malloc(1024), 0, 1024};
  if (!b.s)
    abort();
  b.s[0] = 0;
  return b;
}
static void quote(Buffer *b, const char *s) {
  add(b, "\"");
  for (; *s; s++) {
    unsigned char c = *s;
    if (c == '"' || c == '\\')
      add(b, "\\%c", c);
    else if (c < 32)
      add(b, "\\u%04x", c);
    else
      add(b, "%c", c);
  }
  add(b, "\"");
}
static double monotime(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}
static char hostname_buf[256], node_id[65], os_name[256], cpu_model[256];
static struct utsname uts;
static double cpu_usage, rx_rate, tx_rate, previous_time;
static unsigned long long prev_total, prev_idle, rx, tx, prev_rx, prev_tx;
static void property(const char *path, const char *key, char *out,
                     size_t size) {
  FILE *f = fopen(path, "r");
  if (!f)
    return;
  char line[1024];
  size_t k = strlen(key);
  while (fgets(line, sizeof(line), f))
    if (!strncmp(line, key, k)) {
      char *p = line + k;
      while (*p == ' ' || *p == '\t')
        p++;
      if (*p != '=' && *p != ':')
        continue;
      p++;
      while (*p == ' ' || *p == '\t')
        p++;
      p[strcspn(p, "\r\n")] = 0;
      size_t n = strlen(p);
      if (n >= 2 && ((*p == '"' && p[n - 1] == '"') ||
                     (*p == '\'' && p[n - 1] == '\''))) {
        p[n - 1] = 0;
        p++;
      }
      snprintf(out, size, "%s", p);
      break;
    }
  fclose(f);
}
static void metrics_init(void) {
  gethostname(hostname_buf, sizeof(hostname_buf) - 1);
  uname(&uts);
  snprintf(os_name, sizeof(os_name), "%s", uts.sysname);
  property("/etc/os-release", "PRETTY_NAME", os_name, sizeof(os_name));
  property("/etc/openwrt_release", "DISTRIB_DESCRIPTION", os_name,
           sizeof(os_name));
  const char *keys[] = {"model name", "cpu model", "Processor", "Hardware"};
  for (unsigned i = 0; i < 4 && !cpu_model[0]; i++)
    property("/proc/cpuinfo", keys[i], cpu_model, sizeof(cpu_model));
  char identity[256];
  snprintf(identity, sizeof(identity), "%s", hostname_buf);
  FILE *f = fopen("/etc/machine-id", "r");
  if (f) {
    if (fgets(identity, sizeof(identity), f))
      identity[strcspn(identity, "\r\n")] = 0;
    fclose(f);
  }
  uint8_t h[64];
  crypto_sha512(h, (uint8_t *)identity, strlen(identity));
  for (int i = 0; i < 32; i++)
    snprintf(node_id + i * 2, 3, "%02x", h[i]);
}
static void sample(void) {
  double now = monotime(), dt = now - previous_time;
  FILE *f = fopen("/proc/stat", "r");
  if (f) {
    unsigned long long a = 0, b = 0, c = 0, d = 0, e = 0, g = 0, h = 0, i = 0;
    if (fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &a, &b, &c, &d,
               &e, &g, &h, &i) >= 4) {
      unsigned long long total = a + b + c + d + e + g + h + i, idle = d + e;
      if (prev_total && total > prev_total)
        cpu_usage =
            100.0 * (1.0 - (double)(idle - prev_idle) / (total - prev_total));
      prev_total = total;
      prev_idle = idle;
    }
    fclose(f);
  }
  rx = tx = 0;
  f = fopen("/proc/net/dev", "r");
  if (f) {
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
      char *p = strchr(line, ':');
      if (!p)
        continue;
      *p = 0;
      char *name = line;
      while (isspace((unsigned char)*name))
        name++;
      if (!strcmp(name, "lo"))
        continue;
      unsigned long long r, t;
      if (sscanf(p + 1, "%llu %*u %*u %*u %*u %*u %*u %*u %llu", &r, &t) == 2) {
        rx += r;
        tx += t;
      }
    }
    fclose(f);
  }
  if (previous_time && dt > 0) {
    rx_rate = rx >= prev_rx ? (rx - prev_rx) / dt : 0;
    tx_rate = tx >= prev_tx ? (tx - prev_tx) / dt : 0;
  }
  previous_time = now;
  prev_rx = rx;
  prev_tx = tx;
}
static char *snapshot(const char *name) {
  Buffer b = buffer();
  add(&b, "{\"id\":");
  quote(&b, node_id);
  add(&b, ",\"name\":");
  quote(&b, name);
  add(&b, ",\"hostname\":");
  quote(&b, hostname_buf);
  add(&b, ",\"os\":");
  quote(&b, os_name);
  add(&b, ",\"kernel\":");
  quote(&b, uts.release);
  add(&b, ",\"arch\":");
  quote(&b, uts.machine);
  add(&b, ",\"cpu_model\":");
  quote(&b, cpu_model);
  double loads[3] = {0};
  getloadavg(loads, 3);
  long cores = sysconf(_SC_NPROCESSORS_ONLN);
  unsigned long long mt = 0, ma = 0, mf = 0, mb = 0, mc = 0, st = 0, sf = 0;
  int available = 0;
  FILE *f = fopen("/proc/meminfo", "r");
  if (f) {
    char line[256], key[64];
    unsigned long long v;
    while (fgets(line, sizeof(line), f))
      if (sscanf(line, "%63s %llu", key, &v) == 2) {
        v *= 1024;
        if (!strcmp(key, "MemTotal:"))
          mt = v;
        else if (!strcmp(key, "MemAvailable:")) {
          ma = v;
          available = 1;
        } else if (!strcmp(key, "MemFree:"))
          mf = v;
        else if (!strcmp(key, "Buffers:"))
          mb = v;
        else if (!strcmp(key, "Cached:"))
          mc = v;
        else if (!strcmp(key, "SwapTotal:"))
          st = v;
        else if (!strcmp(key, "SwapFree:"))
          sf = v;
      }
    fclose(f);
  }
  if (!available)
    ma = mf + mb + mc;
  struct statvfs fs;
  unsigned long long disk = 0, used = 0;
  if (!statvfs("/", &fs)) {
    disk = (unsigned long long)fs.f_blocks * fs.f_frsize;
    used = (unsigned long long)(fs.f_blocks - fs.f_bfree) * fs.f_frsize;
  }
  double up = 0;
  unsigned procs = 0;
  f = fopen("/proc/uptime", "r");
  if (f) {
    if (fscanf(f, "%lf", &up) != 1)
      up = 0;
    fclose(f);
  }
  f = fopen("/proc/loadavg", "r");
  if (f) {
    unsigned running;
    if (fscanf(f, "%*f %*f %*f %u/%u", &running, &procs) != 2)
      procs = 0;
    fclose(f);
  }
  unsigned tcp = 0;
  const char *paths[] = {"/proc/net/tcp", "/proc/net/tcp6"};
  for (int k = 0; k < 2; k++) {
    f = fopen(paths[k], "r");
    if (f) {
      char line[1024];
      if (fgets(line, sizeof(line), f))
        while (fgets(line, sizeof(line), f))
          tcp++;
      fclose(f);
    }
  }
  add(&b,
      ",\"cpu_cores\":%ld,\"cpu_usage\":%.2f,\"load\":[%.2f,%.2f,%.2f],\"mem_"
      "total\":%llu,\"mem_used\":%llu,\"swap_total\":%llu,\"swap_used\":%llu,"
      "\"disk_total\":%llu,\"disk_used\":%llu,\"net_rx\":%llu,\"net_tx\":%llu,"
      "\"net_rx_rate\":%.2f,\"net_tx_rate\":%.2f,\"uptime\":%.2f,\"procs\":%u,"
      "\"tcp_conns\":%u,\"temp\":",
      cores > 0 ? cores : 1, cpu_usage, loads[0], loads[1], loads[2], mt,
      mt > ma ? mt - ma : 0, st, st > sf ? st - sf : 0, disk, used, rx, tx,
      rx_rate, tx_rate, up, procs, tcp);
  double temp;
  f = fopen("/sys/class/thermal/thermal_zone0/temp", "r");
  if (f) {
    if (fscanf(f, "%lf", &temp) == 1)
      add(&b, "%.2f", temp / 1000);
    else
      add(&b, "null");
    fclose(f);
  } else
    add(&b, "null");
  add(&b, ",\"ips\":[");
  struct ifaddrs *ifs = NULL;
  int comma = 0;
  if (!getifaddrs(&ifs)) {
    for (struct ifaddrs *p = ifs; p; p = p->ifa_next) {
      if (!p->ifa_addr || (p->ifa_flags & IFF_LOOPBACK))
        continue;
      int af = p->ifa_addr->sa_family;
      void *addr = NULL;
      if (af == AF_INET)
        addr = &((struct sockaddr_in *)p->ifa_addr)->sin_addr;
      else if (af == AF_INET6) {
        struct in6_addr *a = &((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
        if (IN6_IS_ADDR_LINKLOCAL(a))
          continue;
        addr = a;
      }
      char ip[INET6_ADDRSTRLEN];
      if (addr && inet_ntop(af, addr, ip, sizeof(ip))) {
        add(&b, "%s", comma++ ? "," : "");
        quote(&b, ip);
      }
    }
    freeifaddrs(ifs);
  }
  add(&b, "],\"ts\":%lld,\"version\":\"0.1.0\"}", (long long)time(NULL));
  return b.s;
}
#endif
