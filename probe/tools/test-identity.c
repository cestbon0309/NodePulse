#include "../json.h"
#include "../metrics.h"
#include <assert.h>

int main(int argc, char **argv) {
  assert(argc == 2);
  char mac[64] = "", first[65];
  first_mac(argv[1], mac);
  assert(!strcmp(mac, "02:00:00:00:00:01"));
  identify("", "router", mac, "one");
  strcpy(first, node_id);
  identify("", "router", mac, "two");
  assert(strcmp(first, node_id));
  identify("", "router", "02:00:00:00:00:02", "one");
  assert(strcmp(first, node_id));
  identify("", "router", mac, "one");
  assert(!strcmp(first, node_id));
  identify("machine", "router", mac, "one");
  strcpy(first, node_id);
  identify("machine", "different", "", "two");
  assert(!strcmp(first, node_id));
  first_mac("/nonexistent-nodepulse-net", mac);
  identify("", "router", "", NULL);
  assert(strlen(node_id) == 64);
  puts("PASS fallback identity: MAC/name separation, stable machine-id, missing MAC");
  return 0;
}
