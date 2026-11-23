#define _GNU_SOURCE
#define ADMIN 0
#include "../json.h"
#include "../metrics.h"
#include <assert.h>
#include <signal.h>
#include <sys/wait.h>
#ifdef __GLIBC__
#include <gnu/libc-version.h>
#endif
static void controlled(void) {
  fclose(metric_cpu_file); fclose(metric_mem_file); fclose(metric_net_file);
  FILE **streams[] = {&metric_cpu_file, &metric_mem_file, &metric_net_file};
  int writers[3];
  for (int i = 0; i < 3; i++) {
    char path[] = "/tmp/npulse-stream-XXXXXX";
    writers[i] = mkstemp(path); assert(writers[i] >= 0);
    *streams[i] = fopen(path, "r"); assert(*streams[i]); unlink(path);
    setvbuf(*streams[i], metric_buffers[i], _IOFBF, sizeof(metric_buffers[i]));
  }
  prev_total = prev_idle = 0;
  for (int n = 0; n < 5; n++) {
    char cpu[128], mem[128], net[128];
    snprintf(cpu, sizeof(cpu), "cpu %d 0 0 100 0 0 0 0\n", 100 + n * 10);
    snprintf(mem, sizeof(mem), "MemTotal: 100000 kB\nMemAvailable: %d kB\n", 80000 - n * 100);
    snprintf(net, sizeof(net), "eth0: %d 0 0 0 0 0 0 0 %d\n", 1000 + n * 100, 2000 + n * 200);
    const char *values[] = {cpu, mem, net};
    for (int i = 0; i < 3; i++) assert(pwrite(writers[i], values[i], strlen(values[i]), 0) == (ssize_t)strlen(values[i]));
    sample();
    assert(prev_total == (unsigned)(200 + n * 10));
    assert(metric_mu == (unsigned)(20000 + n * 100) * 1024);
    assert(rx == (unsigned)(1000 + n * 100) && tx == (unsigned)(2000 + n * 200));
  }
  for (int i = 0; i < 3; i++) assert(!ftruncate(writers[i], 0));
  sample(); assert(prev_total == 240 && !metric_mu && !rx && !tx);
  for (int i = 0; i < 3; i++) assert(pwrite(writers[i], "invalid\n", 8, 0) == 8);
  sample(); assert(prev_total == 240 && !metric_mu && !rx && !tx);
  for (int i = 0; i < 3; i++) { fclose(*streams[i]); close(writers[i]); }
  puts("PASS controlled persistent streams: partial-read CPU, EOF-read meminfo/net/dev, empty and malformed input");
}
int main(void) {
#ifdef __GLIBC__
  printf("glibc %s\n", gnu_get_libc_version());
#endif
  metrics_init("streams-test");
  assert(metric_cpu_file && metric_mem_file && metric_net_file);
  sample();
  sleep(1); sample(); printf("idle cpu=%.2f\n", cpu_usage);
  unsigned long long first = prev_total;
  pid_t child = fork(); assert(child >= 0);
  if (!child) { volatile unsigned long value = 0; for (;;) value++; }
  int changed = 0, loaded = 0;
  for (int n = 0; n < 8; n++) {
    sleep(1); sample();
    printf("sample %d total=%llu cpu=%.2f mem=%llu rx=%llu tx=%llu load=%.2f\n",
           n, prev_total, cpu_usage, metric_mu, rx, tx, metric_loads[0]);
    if (prev_total > first) changed++;
    if (cpu_usage > 1) loaded++;
  }
  kill(child, SIGKILL); waitpid(child, NULL, 0);
  fflush(stdout);
  assert(changed == 8 && loaded > 0);
  puts("PASS live persistent /proc/stat counters and CPU load update");
  controlled();
  return 0;
}
