#include "../json.h"
#include <ifaddrs.h>
#include <float.h>
#include <assert.h>

static int fixture_interfaces(struct ifaddrs **interfaces);
static void fixture_free(struct ifaddrs *interfaces);
static int fixture_loads(double *loads, int count);
#define getifaddrs fixture_interfaces
#define freeifaddrs fixture_free
#define getloadavg fixture_loads
#include "../metrics.h"

static int address_count = 64;
static int fixture_interfaces(struct ifaddrs **interfaces) {
  static struct ifaddrs entries[64];
  static struct sockaddr_in6 addresses[64];
  for (int i = 0; i < address_count; i++) {
    addresses[i].sin6_family = AF_INET6;
    memset(&addresses[i].sin6_addr, 0xff, sizeof(addresses[i].sin6_addr));
    addresses[i].sin6_addr.s6_addr[0] = 0x20;
    addresses[i].sin6_addr.s6_addr[1] = 0x01;
    addresses[i].sin6_addr.s6_addr[15] = (unsigned char)i;
    entries[i].ifa_addr = (struct sockaddr *)&addresses[i];
    entries[i].ifa_next = i + 1 < address_count ? &entries[i + 1] : NULL;
  }
  *interfaces = address_count ? entries : NULL;
  return 0;
}
static void fixture_free(struct ifaddrs *interfaces) { (void)interfaces; }
static int fixture_loads(double *loads, int count) {
  for (int i = 0; i < count; i++)
    loads[i] = DBL_MAX;
  return count;
}

int main(void) {
  char name[512];
  memset(name, 1, sizeof(name) - 1); name[sizeof(name) - 1] = 0;
  memset(hostname_buf, 1, sizeof(hostname_buf) - 1);
  memset(os_name, 1, sizeof(os_name) - 1);
  memset(cpu_model, 1, sizeof(cpu_model) - 1);
  memset(uts.release, 1, sizeof(uts.release) - 1);
  memset(uts.machine, 1, sizeof(uts.machine) - 1);
  memset(node_id, 'a', sizeof(node_id) - 1);
  cpu_usage = rx_rate = tx_rate = DBL_MAX;
  rx = tx = UINT64_MAX;
  assert(bounded_metric(INFINITY) == 0);
  assert(bounded_metric(NAN) == 0);
  assert(bounded_metric(-DBL_MAX) == -1e12);
  Buffer utf8 = buffer();
  quote_limited(&utf8, "中文", 4);
  assert(!strcmp(utf8.s, "\"中\""));
  free(utf8.s);
  char *json = snapshot(name);
  assert(strlen(json) <= SNAPSHOT_MAX_JSON);
  assert(strlen(json) <= MAX_NODE_JSON);
  puts(json);
  free(json);
  address_count = 0;
  json = snapshot("");
  assert(strstr(json, "\"ips\":[]"));
  free(json);
  return 0;
}
