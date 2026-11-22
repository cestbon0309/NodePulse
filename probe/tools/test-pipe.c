#define main npulse_main
#include "../npulse.c"
#undef main
#include <assert.h>
static int install(int index, int mode, double stamp) {
  int fds[2]; assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, fds));
  RelayPipe *p = &relay_pipes[index];
  assert(!pipe_wire_init(&p->w, fds[0]));
  p->mode = mode; p->peer = -1; p->last = p->deadline = stamp;
  return fds[1];
}
int main(void) {
  pipe_init();
  int peer = install(0, RP_LISTENER, 100);
  pipe_tick(190); assert(relay_pipes[0].mode == RP_LISTENER);
  pipe_tick(191); assert(!relay_pipes[0].mode); char byte; assert(read(peer, &byte, 1) == 0); close(peer);
  peer = install(0, RP_WAIT, 130); pipe_tick(131); assert(!relay_pipes[0].mode); close(peer);
  peer = install(0, RP_RAW, 100); int other = install(1, RP_RAW, 100);
  relay_pipes[0].peer = 1; relay_pipes[1].peer = 0;
  pipe_tick(700); assert(relay_pipes[0].mode == RP_RAW);
  pipe_tick(701); assert(!relay_pipes[0].mode && !relay_pipes[1].mode);
  assert(read(peer, &byte, 1) == 0 && read(other, &byte, 1) == 0); close(peer); close(other);
  PipeWire w; assert(!pipe_wire_init(&w, -1));
  uint8_t *data = calloc(PIPE_BUFFER + 1, 1); assert(data);
  assert(!pipe_append(&w, data, PIPE_BUFFER, PIPE_BUFFER));
  assert(pipe_append(&w, data, 1, PIPE_BUFFER));
  w.sent = PIPE_BUFFER / 2;
  assert(!pipe_append(&w, data, PIPE_BUFFER / 2, PIPE_BUFFER));
  assert(pipe_pending(&w) == PIPE_BUFFER); pipe_wire_clear(&w); free(data);
  double now = monotime(); probe_drop(0);
  assert(probe_next >= now + 2 && probe_backoff == 4);
  for (int i = 0; i < 8; i++) probe_drop(0);
  assert(probe_backoff == 60 && probe_next >= monotime() + 59);
  puts("PASS relay simulated timers: listener 90s, accept deadline, raw idle 600s/paired close; exact 256KB queue bound; reconnect backoff 2..60s");
  return 0;
}
