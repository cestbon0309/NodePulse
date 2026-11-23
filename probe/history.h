#ifndef NP_HISTORY_H
#define NP_HISTORY_H
#include <stdint.h>
#include <string.h>
#define HISTORY_COUNT 120
typedef struct {
  uint64_t ts;
  uint32_t seq;
  double cpu, mem, swap, disk, load[3], rx, tx;
} HistorySample;
typedef struct {
  uint64_t epoch;
  uint32_t seq;
  unsigned count, next;
  HistorySample samples[HISTORY_COUNT];
} History;
static void history_append(History *h, HistorySample s) {
  s.seq = ++h->seq;
  h->samples[h->next] = s;
  h->next = (h->next + 1) % HISTORY_COUNT;
  if (h->count < HISTORY_COUNT) h->count++;
}
static unsigned history_since(const History *h, uint64_t epoch, uint32_t since, int *full) {
  uint32_t distance = h->seq - since;
  *full = !epoch || epoch != h->epoch || distance > h->count;
  return *full ? h->count : distance;
}
static const HistorySample *history_at(const History *h, unsigned offset) {
  return &h->samples[(h->next + HISTORY_COUNT - h->count + offset) % HISTORY_COUNT];
}
#endif
