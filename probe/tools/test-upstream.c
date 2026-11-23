#define _GNU_SOURCE
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
static int fixture_getaddrinfo(const char *host, const char *service,
                               const struct addrinfo *hints, struct addrinfo **result) {
  const char *path = getenv("NPULSE_TEST_DNS");
  if (!path || !host || strcmp(host, "relay.test")) return getaddrinfo(host, service, hints, result);
  char address[128] = {0}, log[1024]; unsigned delay = 0;
  FILE *file = fopen(path, "r");
  int fields = file ? fscanf(file, "%u %127s", &delay, address) : 0;
  if (file) fclose(file);
  snprintf(log, sizeof(log), "%s.calls", path);
  file = fopen(log, "a");
  if (file) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    fprintf(file, "%.6f %s\n", now.tv_sec + now.tv_nsec / 1e9, address); fclose(file);
  }
  sleep(delay);
  if (fields != 2 || !strcmp(address, "fail")) return EAI_AGAIN;
  if (!strcmp(address, "both")) {
    struct addrinfo *other = NULL;
    int error = getaddrinfo("127.0.0.1", service, hints, result);
    if (error) return error;
    error = getaddrinfo("::1", service, hints, &other);
    if (error) { freeaddrinfo(*result); return error; }
    struct addrinfo *last = *result;
    while (last->ai_next) last = last->ai_next;
    last->ai_next = other; return 0;
  }
  return getaddrinfo(address, service, hints, result);
}
#define getaddrinfo fixture_getaddrinfo
#define main probe_main
#include "../npulse.c"
#undef main
#undef getaddrinfo
#include <assert.h>
static void state(const char *text) {
  FILE *file = fopen(getenv("NPULSE_TEST_DNS"), "w"); assert(file);
  fputs(text, file); fclose(file);
}
static void resolved(void) {
  double deadline = monotime() + 7;
  while ((upstream_fd >= 0 || upstream_pid > 0) && monotime() < deadline) {
    upstream_tick(monotime(), "relay.test:9001"); usleep(1000);
  }
  assert(upstream_fd < 0 && !upstream_pid);
}
static void unit(void) {
  state(""); upstream_tick(monotime(), "relay.test:9001"); resolved();
  assert(!upstream_addresses.count && upstream_needed);
  for (int i = 0; i < 100; i++) upstream_tick(upstream_next - .001, "relay.test:9001");
  assert(upstream_fd < 0);
  state("0 127.0.0.1");
  upstream_tick(upstream_next, "relay.test:9001"); resolved();
  assert(upstream_addresses.count == 1 && !upstream_needed);
  UpstreamAddresses cached = upstream_addresses;
  state("0 fail"); upstream_failed();
  upstream_tick(upstream_next, "relay.test:9001"); resolved();
  assert(upstream_needed && !memcmp(&cached, &upstream_addresses, sizeof(cached)));
  state("10 ::1");
  upstream_tick(upstream_next, "relay.test:9001");
  pid_t child = upstream_pid; assert(child > 0);
  double began = monotime(); upstream_tick(upstream_deadline + .001, "relay.test:9001");
  assert(monotime() - began < .5 && upstream_fd < 0 && upstream_needed);
  resolved();
  assert(waitpid(child, NULL, WNOHANG) == -1 && errno == ECHILD);
  assert(!memcmp(&cached, &upstream_addresses, sizeof(cached)));
  publishers[0].fd = -1; publishers[0].frame = malloc(32); assert(publishers[0].frame);
  upstream_needed = 0; publish_tick(monotime()); assert(upstream_needed);
  unsigned candidate = publish_next;
  for (int i = 0; i < 2; i++) {
    publishers[i].address = candidate; publishers[i].generation = upstream_generation;
    publishers[i].frame = malloc(32); assert(publishers[i].frame);
  }
  publish_tick(monotime()); assert(publish_next == candidate + 1);
  publishers[0].address = publish_next; publishers[0].generation = upstream_generation - 1;
  publishers[0].frame = malloc(32); assert(publishers[0].frame);
  publish_tick(monotime()); assert(publish_next == candidate + 1);
  upstream_addresses.count = 0; queue_push(0, "{}", 0);
  assert(!publishers[0].frame && publishers[0].fd < 0);
  upstream_addresses = cached;
#if ADMIN
  pipe_init(); upstream_needed = 0; probe_pipes[0].phase = PP_CONNECT;
  probe_drop(0); assert(upstream_needed);
#endif
  upstream_shutdown();
  puts("PASS upstream unit: empty/failed DNS retries, 30s gate, cached-address preservation, bounded worker timeout/reap, publisher timeout and admin connect-failure invalidation");
  puts("PASS publisher affinity unit: simultaneous channel failures advance once; stale-generation failure cannot change candidate; empty cache skips connect");
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--dns-unit")) { unit(); return 0; }
#if PAIR
  if (argc == 3 && !strcmp(argv[1], "--pair-dns")) {
    group_upstream = argv[2]; relay_token = "dns-token";
    uint8_t hash[64]; crypto_sha512(hash, (const uint8_t *)relay_token, strlen(relay_token));
    memcpy(relay_key, hash, 32); signal(SIGPIPE, SIG_IGN);
    int fd = pair_relay_open(stderr, monotime() + 48, "AAAAAAAAAAAAAAAAAAAAAA", 1);
    upstream_shutdown(); assert(fd >= 0); sleep(1); close(fd);
    puts("PASS actual pairing pipe re-resolved the hostname and connected after address change");
    return 0;
  }
#endif
  return probe_main(argc, argv);
}
