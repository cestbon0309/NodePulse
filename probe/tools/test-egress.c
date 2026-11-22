#define main npulse_main
#include "../npulse.c"
#undef main
#include <assert.h>

int main(void) {
  const char *valid[] = {"1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"};
  const char *bad[] = {"", "host", "1.1.1.1\r\n", "10.0.0.1", "127.0.0.1", "169.254.1.1", "100.64.1.1", "172.16.0.1", "192.168.1.1", "203.0.113.1", "224.0.0.1", "::", "::1", "fe80::1", "2001:db8::1", "::ffff:8.8.8.8"};
  for (size_t i = 0; i < sizeof(valid)/sizeof(*valid); i++) assert(egress_public(valid[i]));
  for (size_t i = 0; i < sizeof(bad)/sizeof(*bad); i++) assert(!egress_public(bad[i]));
  char host[256], path[256];
  assert(!egress_url("http://example.com:80/ip", host, path));
  assert(!strcmp(host, "example.com:80") && !strcmp(path, "/ip"));
  assert(egress_url("https://example.com", host, path));
  assert(egress_url("http://a\r\nb/", host, path));
  assert(egress_url("http://user@host/", host, path));
  egress_service = "off"; egress_tick(1, 1); assert(egress_fd == -1);
  egress_service = "http://example.com"; egress_tick(1, 0); assert(egress_fd == -1);
  egress_provider = 1; egress_tick(1, 1);
  assert(egress_next == 61 && egress_backoff == 120);
  egress_tick(60, 1); assert(egress_fd == -1);
  egress_provider = 1; egress_tick(61, 1);
  assert(egress_next == 181 && egress_backoff == 240);
  egress_provider = 1; egress_backoff = 1920; egress_tick(181, 1);
  assert(egress_backoff == 3600);
  egress_next = 21600; egress_provider = 0; egress_tick(21599, 1); assert(egress_fd == -1);
  puts("PASS egress address/URL validation, disable, exponential failure backoff, 6h scheduling");
  return 0;
}
