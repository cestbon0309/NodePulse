#include "../history.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
  History h = {.epoch = 123};
  int full;
  assert(history_since(&h, 0, 0, &full) == 0 && full);
  for (unsigned i = 1; i <= 125; i++) history_append(&h, (HistorySample){.ts = i, .cpu = i});
  assert(h.count == 120 && h.seq == 125 && history_at(&h, 0)->seq == 6);
  assert(history_at(&h, 119)->cpu == 125);
  assert(history_since(&h, 123, 5, &full) == 120 && !full);
  assert(history_since(&h, 123, 4, &full) == 120 && full);
  assert(history_since(&h, 123, 124, &full) == 1 && !full);
  assert(history_since(&h, 123, 125, &full) == 0 && !full);
  assert(history_since(&h, 123, 126, &full) == 120 && full);
  assert(history_since(&h, 124, 124, &full) == 120 && full);
  h = (History){.epoch = 123, .seq = UINT32_MAX - 2};
  for (unsigned i = 0; i < 5; i++) history_append(&h, (HistorySample){.ts = i});
  assert(h.seq == 2 && history_at(&h, 0)->seq == UINT32_MAX - 1);
  assert(history_since(&h, 123, UINT32_MAX, &full) == 3 && !full);
  assert(history_since(&h, 123, UINT32_MAX - 3, &full) == 5 && full);
  puts("PASS C history: empty/full, 120-record wrap, start-1 boundary, stale/future cursors, epoch change, sequence wrap and missed polls");
}
