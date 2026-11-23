#ifndef NP_PIPE_H
#define NP_PIPE_H
#define PIPE_LISTENERS (ADMIN ? 256 : 64)
#define PIPE_COUNT 64
#define PIPE_SOCKETS (PIPE_LISTENERS + PIPE_COUNT * 2)
#define PIPE_BUFFER (256 * 1024)
#define PIPE_PROBES 5
typedef struct {
  int fd;
  uint8_t *in, *out;
  size_t have, want, sent, outlen;
} PipeWire;
enum { RP_FREE, RP_LISTENER, RP_WAIT, RP_ACK, RP_RAW, RP_PAIR };
typedef struct {
  PipeWire w;
  int mode, peer, phone, draining;
  char gid[65], slot[33], cid[33];
  double last, deadline;
} RelayPipe;
static RelayPipe relay_pipes[PIPE_SOCKETS];
#if ADMIN
enum { PP_CONNECT = 1, PP_SEND, PP_REPLY, PP_LISTEN, PP_READY };
typedef struct {
  PipeWire w;
  int phase;
  char rid[33], cid[33];
  double deadline, attempt, last, ping;
  UpstreamAddresses addresses;
  unsigned next_address;
} ProbePipe;
static ProbePipe probe_pipes[PIPE_PROBES];
static double probe_next;
static unsigned probe_generation;
static int probe_backoff = 2;
#endif
static int pipe_wire_init(PipeWire *w, int fd) {
  memset(w, 0, sizeof(*w)); w->fd = -1; w->want = 4;
  w->in = malloc(5);
  if (!w->in) return -1;
  w->fd = fd; return 0;
}
static void pipe_wire_clear(PipeWire *w) {
  if (w->fd >= 0) close(w->fd);
  free(w->in); free(w->out); memset(w, 0, sizeof(*w)); w->fd = -1;
}
static size_t pipe_pending(PipeWire *w) { return w->outlen - w->sent; }
static int pipe_append(PipeWire *w, const uint8_t *data, size_t n, size_t limit) {
  size_t pending = pipe_pending(w);
  if (pending > limit || n > limit - pending) return -1;
  if (w->sent) memmove(w->out, w->out + w->sent, pending);
  w->outlen = pending; w->sent = 0;
  uint8_t *p = realloc(w->out, pending + n);
  if (!p) return -1;
  w->out = p; memcpy(p + pending, data, n); w->outlen += n; return 0;
}
static int pipe_json(PipeWire *w, const char *json) {
  size_t n; uint8_t *p = frame(json, &n, relay_key);
  if (!p) return -1;
  int result = pipe_append(w, p, n, 16384); free(p); return result;
}
static int pipe_flush(PipeWire *w) {
  if (!pipe_pending(w)) return 0;
  ssize_t n = send(w->fd, w->out + w->sent, pipe_pending(w), 0);
  if (n <= 0) return n < 0 && (errno == EAGAIN || errno == EINTR) ? 0 : -1;
  w->sent += (size_t)n;
  if (w->sent == w->outlen) { free(w->out); w->out = NULL; w->outlen = w->sent = 0; }
  return 1;
}
static int pipe_read_json(PipeWire *w, char **json) {
  ssize_t n = recv(w->fd, w->in + w->have, w->want - w->have, 0);
  if (n <= 0) return n < 0 && (errno == EAGAIN || errno == EINTR) ? 0 : -1;
  w->have += (size_t)n;
  if (w->have != w->want) return 0;
  if (w->want == 4) {
    uint32_t be; memcpy(&be, w->in, 4); size_t len = ntohl(be);
    if (!len || len > 4096) return -1;
    uint8_t *p = realloc(w->in, len + 33);
    if (!p) return -1;
    w->in = p; w->want = len + 32; return 0;
  }
  *json = unframe(w->in, w->want, relay_key);
  w->have = 0; w->want = 4;
  return *json ? 1 : -1;
}
static void relay_drop(int index) {
  RelayPipe *p = &relay_pipes[index];
  if (!p->mode) return;
  int peer = p->peer;
  pipe_wire_clear(&p->w); memset(p, 0, sizeof(*p)); p->w.fd = -1; p->peer = -1;
  if (peer >= 0) { relay_pipes[peer].peer = -1; relay_drop(peer); }
}
static int relay_free(void) {
  for (int i = 0; i < PIPE_SOCKETS; i++) if (!relay_pipes[i].mode) return i;
  return -1;
}
#if PAIR
static int pair_pipe_request(Json *j, time_t now, int fd) {
  int listen = eq(j, field(j, 0, "op"), "ppair"), connect = eq(j, field(j, 0, "op"), "pconnect");
  if (!listen && !connect) return -1;
  char *rid = string(j, field(j, 0, "rid")); uint8_t random[5], raw[16];
  int bad = hex_decode(raw, rid, 16) || group_replay("npulse-pair", rid, now); free(rid);
  if (bad) return 0;
  int index = relay_free();
  if (index < 0) return 0;
  int waiting = -1, pending = 0, active = 0;
  for (int i = 0; i < PIPE_SOCKETS; i++) {
    if (relay_pipes[i].mode == RP_PAIR) pending++;
    if (relay_pipes[i].mode && relay_pipes[i].phone) active++;
  }
  char code[9] = {0};
  if (listen) {
    int v = field(j, 0, "v");
    if (v < 0 || j->t[v].type != '1' || j->t[v].end - j->t[v].start != 1 || pending >= 64) return 0;
    int unique = 0;
    for (int attempt = 0; attempt < 8 && !unique; attempt++) {
      if (random_bytes(random, 5)) return 0;
      uint64_t value = 0; for (int i = 0; i < 5; i++) value = value << 8 | random[i];
      for (int i = 7; i >= 0; i--, value >>= 5) code[i] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"[value & 31];
      unique = 1;
      for (int i = 0; i < PIPE_SOCKETS; i++) if (relay_pipes[i].mode == RP_PAIR && !strcmp(relay_pipes[i].cid, code)) unique = 0;
    }
    if (!unique) return 0;
  } else {
    static double tokens = 32, last;
    double tick = monotime(); if (!last) last = tick;
    tokens += tick - last; if (tokens > 32) tokens = 32; last = tick;
    if (tokens < 1 || active >= PIPE_COUNT) return 0;
    tokens--;
    char *text = string(j, field(j, 0, "code"));
    if (!text || strlen(text) > 32) { free(text); return 0; }
    size_t n = 0;
    for (const char *s = text; *s; s++) {
      if (*s == '-') continue;
      char ch = (char)toupper((unsigned char)*s);
      if (ch == 'O') ch = '0';
      if (ch == 'I' || ch == 'L') ch = '1';
      if (n == 8 || !strchr("0123456789ABCDEFGHJKMNPQRSTVWXYZ", ch)) { n = 0; break; }
      code[n++] = ch;
    }
    free(text); if (n != 8) return 0;
    for (int i = 0; i < PIPE_SOCKETS; i++) if (relay_pipes[i].mode == RP_PAIR && !strcmp(relay_pipes[i].cid, code) && monotime() < relay_pipes[i].deadline) waiting = i;
    if (waiting < 0) return 0;
  }
  PipeWire fresh;
  if (pipe_wire_init(&fresh, fd)) return 0;
  char ack[80]; snprintf(ack, sizeof(ack), "{\"ok\":true,\"code\":\"%.4s-%.4s\"}", code, code + 4);
  if (pipe_json(&fresh, listen ? ack : "{\"ok\":true}") ||
      (!listen && pipe_json(&relay_pipes[waiting].w, "{\"ok\":true}"))) {
    fresh.fd = -1; pipe_wire_clear(&fresh); if (waiting >= 0) relay_drop(waiting); return 0;
  }
  RelayPipe *p = &relay_pipes[index]; memset(p, 0, sizeof(*p)); p->w = fresh; p->peer = waiting;
  p->mode = listen ? RP_PAIR : RP_ACK; p->last = monotime(); p->deadline = p->last + (listen ? 600 : 10);
  p->phone = !listen; snprintf(p->cid, sizeof(p->cid), "%s", code);
  if (!listen) { RelayPipe *probe = &relay_pipes[waiting]; probe->peer = index; probe->mode = RP_ACK; probe->deadline = p->deadline; probe->last = p->last; }
  return 1;
}
#endif
#if ADMIN
static int pipe_request(Json *j, long long stamp, time_t now, int fd, char **response) {
  char *op = string(j, field(j, 0, "op"));
  int listening = op && !strcmp(op, "glisten"), connecting = op && !strcmp(op, "gconnect"), accepting = op && !strcmp(op, "gaccept");
  if (!listening && !connecting && !accepting) { free(op); return -1; }
  char *gid = string(j, field(j, 0, "gid")), *slot = string(j, field(j, 0, "slot"));
  char *rid = string(j, field(j, 0, "rid")), *sig = string(j, field(j, 0, "sig"));
  char *cid = accepting ? string(j, field(j, 0, "cid")) : NULL;
  uint8_t pub[32], signature[64], bytes[16]; int result = 0;
  if (hex_decode(pub, gid, 32) || hex_decode(bytes, slot, 16) || hex_decode(bytes, rid, 16) ||
      hex_decode(signature, sig, 64) || (accepting && hex_decode(bytes, cid, 16))) goto done;
  Buffer message = buffer();
  add(&message, "npulse-%s\n%s\n%s\n", op, gid, slot);
  if (accepting) add(&message, "%s\n", cid);
  add(&message, "%lld\n%s", stamp, rid);
  int bad = crypto_ed25519_check(signature, pub, (const uint8_t *)message.s, message.n);
  free(message.s);
  if (bad || group_replay(gid, rid, now)) goto done;
  int listener = -1, waiting = -1, listeners = 0, total = 0, per_group = 0;
  for (int i = 0; i < PIPE_SOCKETS; i++) {
    RelayPipe *p = &relay_pipes[i];
    if (p->mode == RP_LISTENER) {
      listeners++;
      if (!strcmp(p->gid, gid) && !strcmp(p->slot, slot)) listener = i;
    }
    if (p->mode && p->phone) { total++; if (!strcmp(p->gid, gid)) per_group++; }
    if (accepting && p->mode == RP_WAIT && !strcmp(p->gid, gid) && !strcmp(p->slot, slot) && !strcmp(p->cid, cid)) waiting = i;
  }
  if (connecting && listener < 0) { *response = strdup("{\"ok\":false,\"err\":\"offline\"}"); goto done; }
  if ((listening && listener < 0 && listeners >= PIPE_LISTENERS) ||
      (connecting && (total >= PIPE_COUNT || per_group >= 4)) || (accepting && waiting < 0)) goto done;
  int index = listening && listener >= 0 ? listener : relay_free();
  if (index < 0) goto done;
  PipeWire fresh;
  if (pipe_wire_init(&fresh, fd)) goto done;
  char new_cid[33] = {0};
  if (listening) {
    char ack[80]; snprintf(ack, sizeof(ack), "{\"ok\":true,\"rid\":\"%s\"}", rid);
    if (pipe_json(&fresh, ack)) goto failed;
  } else if (connecting) {
    int unique = 0;
    for (int attempt = 0; attempt < 8 && !unique; attempt++) {
      if (random_bytes(bytes, 16)) goto failed;
      hex_encode(new_cid, bytes, 16); unique = 1;
      for (int i = 0; i < PIPE_SOCKETS; i++) if (relay_pipes[i].mode && relay_pipes[i].phone && !strcmp(relay_pipes[i].cid, new_cid)) unique = 0;
    }
    if (!unique) goto failed;
    char incoming[80]; snprintf(incoming, sizeof(incoming), "{\"op\":\"incoming\",\"cid\":\"%s\"}", new_cid);
    if (pipe_json(&relay_pipes[listener].w, incoming)) { relay_drop(listener); goto failed; }
  } else {
    if (pipe_json(&fresh, "{\"ok\":true}") || pipe_json(&relay_pipes[waiting].w, "{\"ok\":true}")) { relay_drop(waiting); goto failed; }
  }
  if (listening && listener >= 0) relay_drop(listener);
  RelayPipe *p = &relay_pipes[index];
  memset(p, 0, sizeof(*p)); p->w = fresh; p->peer = -1;
  snprintf(p->gid, sizeof(p->gid), "%s", gid); snprintf(p->slot, sizeof(p->slot), "%s", slot);
  p->mode = listening ? RP_LISTENER : connecting ? RP_WAIT : RP_ACK;
  p->last = monotime(); p->deadline = p->last + (connecting ? 30 : 10);
  p->phone = connecting;
  if (connecting) snprintf(p->cid, sizeof(p->cid), "%s", new_cid);
  if (accepting) {
    RelayPipe *phone = &relay_pipes[waiting];
    p->peer = waiting; phone->peer = index; phone->mode = RP_ACK;
    phone->last = p->last; phone->deadline = p->deadline;
  }
  result = 1; goto done;
failed:
  fresh.fd = -1; pipe_wire_clear(&fresh);
done:
  free(op); free(gid); free(slot); free(rid); free(sig); free(cid); return result;
}
static char *probe_request(const char *op, const char *cid, char rid[33]) {
  uint8_t random[16], signature[64]; char slot[33], sig[129];
  if (random_bytes(random, 16)) return NULL;
  hex_encode(rid, random, 16); group_slot(slot, node_id);
  long long stamp = (long long)time(NULL);
  Buffer message = buffer(); add(&message, "npulse-%s\n%s\n%s\n", op, group_id, slot);
  if (cid) add(&message, "%s\n", cid);
  add(&message, "%lld\n%s", stamp, rid);
  crypto_ed25519_sign(signature, signing_key, (const uint8_t *)message.s, message.n); free(message.s);
  hex_encode(sig, signature, 64);
  Buffer b = buffer(); add(&b, "{\"op\":\"%s\",\"ts\":%lld,\"rid\":\"%s\",\"gid\":\"%s\",\"slot\":\"%s\",\"sig\":\"%s\"", op, stamp, rid, group_id, slot, sig);
  if (cid) add(&b, ",\"cid\":\"%s\"", cid);
  add(&b, "}"); return b.s;
}
static void probe_drop(int i) {
  if (probe_pipes[i].w.fd >= 0 || probe_pipes[i].phase == PP_CONNECT) upstream_failed();
  pipe_wire_clear(&probe_pipes[i].w); memset(&probe_pipes[i], 0, sizeof(probe_pipes[i])); probe_pipes[i].w.fd = -1;
  if (!i) { probe_next = monotime() + probe_backoff; probe_backoff = probe_backoff >= 30 ? 60 : probe_backoff * 2; }
}
static int probe_next_address(int i) {
  ProbePipe *p = &probe_pipes[i];
  if (p->w.fd >= 0) close(p->w.fd);
  p->w.fd = -1;
  while (p->next_address < p->addresses.count) {
    int fd = upstream_socket(&p->addresses.entries[p->next_address++]);
    if (fd < 0) continue;
    p->w.fd = fd; p->attempt = monotime() + 3; return 0;
  }
  return -1;
}
static void probe_open(int i, const char *cid) {
  ProbePipe *p = &probe_pipes[i];
  if (!upstream_addresses.count) return;
  p->addresses = upstream_addresses; p->next_address = 0;
  if (pipe_wire_init(&p->w, -1)) { probe_drop(i); return; }
  char *json = probe_request(i ? "gaccept" : "glisten", cid, p->rid);
  int bad = !json || pipe_json(&p->w, json); free(json);
  if (bad) { probe_drop(i); return; }
  if (cid) snprintf(p->cid, sizeof(p->cid), "%s", cid);
  p->phase = PP_CONNECT; p->deadline = monotime() + 10;
  if (probe_next_address(i)) probe_drop(i);
}
#endif
static void pipe_init(void) {
  for (int i = 0; i < PIPE_SOCKETS; i++) { relay_pipes[i].w.fd = -1; relay_pipes[i].peer = -1; }
#if ADMIN
  for (int i = 0; i < PIPE_PROBES; i++) probe_pipes[i].w.fd = -1;
#endif
}
static void pipe_tick(double now) {
  for (int i = 0; i < PIPE_SOCKETS; i++) {
    RelayPipe *p = &relay_pipes[i];
    if ((p->mode == RP_LISTENER && now - p->last > 90) || (p->mode == RP_RAW && now - p->last > 600) ||
        ((p->mode == RP_PAIR || p->draining) && now > p->deadline) ||
        ((p->mode == RP_WAIT || p->mode == RP_ACK) && now > p->deadline)) relay_drop(i);
  }
#if ADMIN
  if (!group_upstream || !admin_key_count) return;
  if (probe_generation != upstream_generation) {
    probe_generation = upstream_generation;
    if (probe_pipes[0].w.fd < 0) { probe_next = now; probe_backoff = 2; }
  }
  for (int i = 0; i < PIPE_PROBES; i++) {
    ProbePipe *p = &probe_pipes[i];
    if (p->w.fd < 0) continue;
    if (p->phase == PP_CONNECT && now > p->attempt && now <= p->deadline) {
      if (probe_next_address(i)) probe_drop(i);
      continue;
    }
    if ((p->phase == PP_LISTEN && now - p->last > 90) || (p->phase != PP_LISTEN && p->phase != PP_READY && now > p->deadline)) { probe_drop(i); continue; }
    if (p->phase == PP_LISTEN && now >= p->ping && !pipe_pending(&p->w)) {
      if (pipe_json(&p->w, "{\"op\":\"gping\"}")) { probe_drop(i); continue; }
      p->ping = now + 30;
    }
  }
  if (probe_pipes[0].w.fd < 0 && now >= probe_next) probe_open(0, NULL);
#endif
}
static int pipe_poll(struct pollfd *pf) {
  for (int i = 0; i < PIPE_SOCKETS; i++) {
    RelayPipe *p = &relay_pipes[i]; short events = pipe_pending(&p->w) ? POLLOUT : 0;
    if (p->mode == RP_LISTENER || p->mode == RP_WAIT || p->mode == RP_PAIR || (p->mode == RP_RAW && !p->draining && pipe_pending(&relay_pipes[p->peer].w) < PIPE_BUFFER)) events |= POLLIN;
    pf[i] = (struct pollfd){p->draining && !pipe_pending(&p->w) ? -1 : p->w.fd, events, 0};
  }
#if ADMIN
  for (int i = 0; i < PIPE_PROBES; i++) {
    ProbePipe *p = &probe_pipes[i];
    short events = p->phase == PP_CONNECT || pipe_pending(&p->w) ? POLLOUT : 0;
    if (p->phase == PP_REPLY || p->phase == PP_LISTEN) events |= POLLIN;
    pf[PIPE_SOCKETS + i] = (struct pollfd){p->w.fd, events, 0};
  }
  return PIPE_SOCKETS + PIPE_PROBES;
#else
  return PIPE_SOCKETS;
#endif
}
static void pipe_io(struct pollfd *pf) {
  for (int i = 0; i < PIPE_SOCKETS; i++) {
    RelayPipe *p = &relay_pipes[i]; short events = pf[i].revents;
    if (!p->mode) continue;
    if ((events & (POLLERR | POLLNVAL)) || ((events & POLLHUP) && p->mode != RP_RAW)) { relay_drop(i); continue; }
    if (p->draining && !pipe_pending(&p->w) && !pipe_pending(&relay_pipes[p->peer].w)) { relay_drop(i); continue; }
    if ((p->mode == RP_WAIT || p->mode == RP_PAIR) && (events & POLLIN)) {
      uint8_t byte; ssize_t n = recv(p->w.fd, &byte, 1, MSG_PEEK);
      if (n >= 0 || (errno != EAGAIN && errno != EINTR)) relay_drop(i);
      continue;
    }
    if (events & POLLOUT) {
      int sent = pipe_flush(&p->w);
      if (sent < 0) { relay_drop(i); continue; }
      if (sent && p->mode != RP_LISTENER) { p->last = monotime(); if (p->peer >= 0) relay_pipes[p->peer].last = p->last; }
    }
    if (p->mode == RP_ACK && !pipe_pending(&p->w) && !pipe_pending(&relay_pipes[p->peer].w)) {
      p->mode = relay_pipes[p->peer].mode = RP_RAW;
    }
    if (p->mode == RP_RAW && !p->draining && (events & (POLLIN | POLLHUP))) {
      RelayPipe *peer = &relay_pipes[p->peer]; uint8_t data[16384];
      size_t room = PIPE_BUFFER - pipe_pending(&peer->w);
      if (!room) continue;
      ssize_t n = recv(p->w.fd, data, room < sizeof(data) ? room : sizeof(data), 0);
      if (n > 0) {
        if (pipe_append(&peer->w, data, (size_t)n, PIPE_BUFFER)) { relay_drop(i); continue; }
        p->last = peer->last = monotime();
      } else if (!n) { p->draining = peer->draining = 1; p->deadline = peer->deadline = monotime() + 5; }
      else if (errno != EAGAIN && errno != EINTR) relay_drop(i);
    } else if (p->mode == RP_LISTENER && (events & POLLIN)) {
      char *json = NULL; int result = pipe_read_json(&p->w, &json);
      if (result < 0) { relay_drop(i); continue; }
      if (!result) continue;
      Json j;
      int bad = parse(&j, json) || !eq(&j, field(&j, 0, "op"), "gping");
      free(json);
      if (bad || pipe_json(&p->w, "{\"ok\":true}")) relay_drop(i);
      else p->last = monotime();
    }
  }
#if ADMIN
  for (int i = 0; i < PIPE_PROBES; i++) {
    ProbePipe *p = &probe_pipes[i]; short events = pf[PIPE_SOCKETS + i].revents;
    if (p->w.fd < 0 || p->phase == PP_READY) continue;
    if (events & (POLLERR | POLLHUP | POLLNVAL)) {
      if (p->phase != PP_CONNECT || probe_next_address(i)) probe_drop(i);
      continue;
    }
    if (p->phase == PP_CONNECT && (events & POLLOUT)) {
      int error = 0; socklen_t len = sizeof(error);
      if (getsockopt(p->w.fd, SOL_SOCKET, SO_ERROR, &error, &len) || error) {
        if (probe_next_address(i)) probe_drop(i);
        continue;
      }
      p->addresses.count = p->next_address = 0;
      p->phase = PP_SEND;
    }
    if (events & POLLOUT) {
      if (pipe_flush(&p->w) < 0) { probe_drop(i); continue; }
      if (p->phase == PP_SEND && !pipe_pending(&p->w)) p->phase = PP_REPLY;
    }
    if (!(events & POLLIN)) continue;
    char *json = NULL; int result = pipe_read_json(&p->w, &json);
    if (result < 0) { probe_drop(i); continue; }
    if (!result) continue;
    Json j; int bad = parse(&j, json);
    if (!bad && p->phase == PP_REPLY) {
      int ok = 0; bad = admin_bool(&j, "ok", &ok) || !ok;
      if (!bad && !i) {
        char *rid = string(&j, field(&j, 0, "rid")); bad = !rid || strcmp(rid, p->rid); free(rid);
      }
      if (!bad) { p->phase = i ? PP_READY : PP_LISTEN; p->last = monotime(); p->ping = p->last + 30; if (!i) probe_backoff = 2; }
    } else if (!bad && p->phase == PP_LISTEN) {
      if (eq(&j, field(&j, 0, "op"), "incoming")) {
        char *cid = string(&j, field(&j, 0, "cid")); uint8_t raw[16]; bad = hex_decode(raw, cid, 16);
        if (!bad) for (int k = 1; k < PIPE_PROBES; k++) if (probe_pipes[k].w.fd < 0) { probe_open(k, cid); break; }
        free(cid);
      } else { int ok; bad = admin_bool(&j, "ok", &ok) || !ok; }
      if (!bad) p->last = monotime();
    } else bad = 1;
    free(json); if (bad) probe_drop(i);
  }
#endif
}
#if ADMIN
static int probe_take(void) {
  for (int i = 1; i < PIPE_PROBES; i++) if (probe_pipes[i].phase == PP_READY) {
    int fd = probe_pipes[i].w.fd;
    probe_pipes[i].w.fd = -1; probe_drop(i); return fd;
  }
  return -1;
}
#endif
static void pipe_shutdown(void) {
  for (int i = 0; i < PIPE_SOCKETS; i++) relay_drop(i);
#if ADMIN
  for (int i = 0; i < PIPE_PROBES; i++) probe_drop(i);
#endif
}
#endif
