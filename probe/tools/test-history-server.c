#define _GNU_SOURCE
#include "../json.h"
#include "../metrics.h"
#include "../history.h"
static int prefill;
static void history_metrics_init(const char *name);
#define metrics_init history_metrics_init
#define main probe_main
#include "../npulse.c"
#undef main
#undef metrics_init
static void history_metrics_init(const char *name) {
  metrics_init(name);
  identify("", hostname_buf, "history-fixture", name);
  if (prefill) for (unsigned i = 120; i; i--)
    history_append(&history, (HistorySample){.ts = (uint64_t)time(NULL) - i});
}
int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "--prefill")) { prefill = 1; argc--; argv++; }
  return probe_main(argc, argv);
}
