#define _GNU_SOURCE
#ifndef ADMIN
#define ADMIN 1
#endif
#ifndef PAIR
#define PAIR ADMIN
#endif
#if ADMIN
#define _FILE_OFFSET_BITS 64
#define ADMIN_FLAGS "A:"
#else
#define ADMIN_FLAGS ""
#endif
#include "json.h"
#include "metrics.h"
#include "vendor/monocypher-ed25519.h"
#include "vendor/monocypher.h"
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#define MAX_FRAME (256 * 1024)
static int random_bytes(void *p, size_t n);
#include "group.h"
#define CLIENTS 32
#define RELAY_NODES 64
typedef char RelayFrameBudget[(RELAY_NODES * (MAX_NODE_JSON + 64) + MAX_NODE_JSON + 128 < MAX_FRAME) ? 1 : -1];
static uint8_t key[32];
static const char *secret, *display, *listen_addr, *http_addr, *upstream;
static int interval = 5;
static volatile sig_atomic_t running = 1;
static void stop(int sig) {
  (void)sig;
  running = 0;
}
#if ADMIN || PAIR
#include "session.h"
#endif
typedef struct {
  char *json, *id;
  time_t seen;
} Node;
static Node nodes[RELAY_NODES];
static uint8_t nonces[256][12];
static time_t nonce_seen[256];
static unsigned nonce_pos;
static int random_bytes(void *p, size_t n) {
  int f = open("/dev/urandom", O_RDONLY);
  if (f < 0)
    return -1;
  size_t off = 0;
  while (off < n) {
    ssize_t r = read(f, (char *)p + off, n - off);
    if (r <= 0) {
      close(f);
      return -1;
    }
    off += (size_t)r;
  }
  close(f);
  return 0;
}
static int endpoint_addresses(const char *s, const char *def, int server, struct addrinfo **addresses) {
  char host[256], port[16];
  const char *p = strrchr(s, ':');
  if (*s == '[') {
    const char *end = strchr(s, ']');
    if (!end || end[1] != ':' || (size_t)(end - s - 1) >= sizeof(host))
      return -1;
    memcpy(host, s + 1, (size_t)(end - s - 1));
    host[end - s - 1] = 0;
    snprintf(port, sizeof(port), "%s", end + 2);
  } else if (p) {
    if ((size_t)(p - s) >= sizeof(host))
      return -1;
    memcpy(host, s, (size_t)(p - s));
    host[p - s] = 0;
    snprintf(port, sizeof(port), "%s", p + 1);
  } else {
    snprintf(host, sizeof(host), "%s", def);
    snprintf(port, sizeof(port), "%s", s);
  }
  char *end;
  long pn = strtol(port, &end, 10);
  if (*end || pn < 1 || pn > 65535)
    return -1;
  struct addrinfo hints = {0}, *res = NULL;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  hints.ai_flags = server > 0 ? AI_PASSIVE : 0;
  if (getaddrinfo(*host ? host : NULL, port, &hints, &res))
    return -1;
  *addresses = res;
  return 0;
}
static int endpoint(const char *s, const char *def, int server) {
  struct addrinfo *res = NULL;
  if (endpoint_addresses(s, def, server, &res)) return -1;
  int fd = -1;
  for (struct addrinfo *a = res; a; a = a->ai_next) {
    fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    if (fd < 0)
      continue;
#if ADMIN
    fcntl(fd, F_SETFD, FD_CLOEXEC);
#endif
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (server > 0) {
      if (!bind(fd, a->ai_addr, a->ai_addrlen) && !listen(fd, 32))
        break;
    } else {
      int r = connect(fd, a->ai_addr, a->ai_addrlen);
      if (!r)
        break;
      if (errno == EINPROGRESS) {
        struct pollfd pf = {fd, POLLOUT, 0};
        int err = 0;
        socklen_t len = sizeof(err);
        if (poll(&pf, 1, 1000) > 0 &&
            !getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) && !err)
          break;
      }
    }
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  return fd;
}
static uint8_t *frame(const char *s, size_t *size, const uint8_t transport_key[32]) {
  size_t n = strlen(s);
  if (!n || n > MAX_FRAME)
    return NULL;
  uint8_t *p = malloc(n + 32);
  if (!p)
    return NULL;
  uint32_t be = htonl((uint32_t)n);
  memcpy(p, &be, 4);
  if (random_bytes(p + 4, 12)) {
    free(p);
    return NULL;
  }
  crypto_aead_ctx ctx;
  crypto_aead_init_ietf(&ctx, transport_key, p + 4);
  crypto_aead_write(&ctx, p + 16, p + 16 + n, p, 4, (const uint8_t *)s, n);
  crypto_wipe(&ctx, sizeof(ctx));
  *size = n + 32;
  return p;
}
typedef struct Admin Admin;
static char *unframe(const uint8_t *p, size_t total, const uint8_t transport_key[32]) {
  if (total < 32) return NULL;
  uint32_t be; memcpy(&be, p, 4); size_t n = ntohl(be);
  if (!n || n > MAX_FRAME || total != n + 32) return NULL;
  char *plain = malloc(n + 1);
  if (!plain) return NULL;
  crypto_aead_ctx ctx; crypto_aead_init_ietf(&ctx, transport_key, p + 4);
  int bad = crypto_aead_read(&ctx, (uint8_t *)plain, p + n + 16, p, 4, p + 16, n);
  crypto_wipe(&ctx, sizeof(ctx));
  if (bad || memchr(plain, 0, n)) { crypto_wipe(plain, n); free(plain); return NULL; }
  plain[n] = 0;
  return plain;
}
#if ADMIN
#include "admin.h"
#endif
#if ADMIN || PAIR
#include "pipe.h"
#define ADMIN_POLLS (PIPE_SOCKETS + (ADMIN ? CLIENTS * 4 + PIPE_PROBES : 0))
#else
#define ADMIN_POLLS 0
#endif
#if PAIR
#include "pairing.h"
#endif
typedef struct {
  int fd, http, relay;
  uint8_t *in, *out;
  size_t have, want, sent, outlen, body;
  double deadline;
  int taken;
#if ADMIN
  Admin *admin;
  int pipe_hello;
#endif
} Client;
static char *nodes_json(const char *rid) {
  Buffer b = buffer();
  add(&b, "{\"ok\":true,");
  if (rid) {
    add(&b, "\"rid\":");
    quote(&b, rid);
    add(&b, ",");
  }
  add(&b, "\"nodes\":[");
  int comma = 0;
  if (listen_addr || (http_addr && !(relay_addr || (relay_token && !secret)))) {
    char *s = snapshot(display);
    s[strlen(s) - 1] = 0;
    add(&b, "%s,\"relay\":false}", s);
    free(s);
    comma = 1;
  }
  time_t now = time(NULL);
  for (int i = 0; i < RELAY_NODES; i++) {
    Node *n = &nodes[i];
    if (n->json && now - n->seen > 600) {
      free(n->json);
      free(n->id);
      memset(n, 0, sizeof(*n));
    }
    if (n->json && b.n + strlen(n->json) + 64 + 2 <= MAX_FRAME)
      add(&b, "%s%.*s,\"relay\":true,\"last_seen\":%lld}", comma++ ? "," : "",
          (int)strlen(n->json) - 1, n->json, (long long)n->seen);
  }
  add(&b, "]}");
  return b.s;
}
static char *request(uint8_t *p, size_t total, int relay, Client *client) {
#if !ADMIN
  (void)client;
#endif
  char *plain = unframe(p, total, relay ? relay_key : key);
  if (!plain) return NULL;
  size_t n = strlen(plain);
  Json j;
  char *response = NULL;
  if (memchr(plain, 0, n) || parse(&j, plain))
    goto done;
  int ts = field(&j, 0, "ts"), op = field(&j, 0, "op");
  if (ts < 0 || j.t[ts].type == '"')
    goto done;
  char *end;
  long long stamp = strtoll(plain + j.t[ts].start, &end, 10);
  time_t now = time(NULL);
  if (end != plain + j.t[ts].end || stamp < (long long)now - 120 ||
      stamp > (long long)now + 120)
    goto done;
  for (int i = 0; i < 256; i++)
    if (nonce_seen[i] && now - nonce_seen[i] <= 240 &&
        !memcmp(nonces[i], p + 4, 12))
      goto done;
  memcpy(nonces[nonce_pos], p + 4, 12);
  nonce_seen[nonce_pos] = now;
  nonce_pos = (nonce_pos + 1) % 256;
  if (relay) {
    if (client) {
      int result = -1;
#if PAIR
      result = pair_pipe_request(&j, now, client->fd);
#endif
#if ADMIN
      if (result < 0) result = pipe_request(&j, stamp, now, client->fd, &response);
#endif
      if (result >= 0) { client->taken = result; goto done; }
    }
    response = group_request(&j, stamp, now);
    goto done;
  }
#if ADMIN
  if (eq(&j, op, "admin")) {
    if (client) response = admin_hello(&j, stamp, now, &client->admin, secret);
    goto done;
  }
#endif
  if (eq(&j, op, "get")) {
    int token = field(&j, 0, "rid");
    char *rid = token >= 0 ? string(&j, token) : NULL;
    if (token >= 0 && (!rid || strlen(rid) != 32 ||
        strspn(rid, "0123456789abcdefABCDEF") != 32)) {
      free(rid);
      goto done;
    }
    response = nodes_json(rid);
    free(rid);
  }
  else if (eq(&j, op, "push")) {
    int obj = field(&j, 0, "node"), id = field(&j, obj, "id");
    if (obj < 0 || j.t[obj].type != '{' ||
        j.t[obj].end - j.t[obj].start > MAX_NODE_JSON)
      goto done;
    if (id < 0 || j.t[id].type != '"' || j.t[id].end - j.t[id].start < 3 ||
        j.t[id].end - j.t[id].start > 258)
      goto done;
    /* Relay metadata belongs to this server, never to the sender. */
    if (field(&j, obj, "relay") >= 0 || field(&j, obj, "last_seen") >= 0)
      goto done;
    char *ident = string(&j, id);
    if (!ident)
      goto done;
    int slot = -1;
    for (int i = 0; i < RELAY_NODES; i++)
      if (nodes[i].id && !strcmp(nodes[i].id, ident)) {
        slot = i;
        break;
      }
    if (slot < 0)
      for (int i = 0; i < RELAY_NODES; i++)
        if (!nodes[i].json || now - nodes[i].seen > 600) {
          slot = i;
          break;
        }
    if (slot >= 0) {
      char *copy = strndup(plain + j.t[obj].start,
                           (size_t)(j.t[obj].end - j.t[obj].start));
      if (copy) {
        free(nodes[slot].json);
        free(nodes[slot].id);
        nodes[slot] = (Node){copy, ident, now};
        ident = NULL;
        response = strdup("{\"ok\":true}");
      }
    }
    free(ident);
  }
done:
  crypto_wipe(plain, n);
  free(plain);
  return response;
}
static int same_secret(const char *s, size_t n) {
  size_t len = strlen(secret), max = n > len ? n : len;
  unsigned diff = (unsigned)(n ^ len);
  for (size_t i = 0; i < max; i++)
    diff |= (unsigned char)(i < n ? s[i] : 0) ^
            (unsigned char)(i < len ? secret[i] : 0);
  return diff == 0;
}
static char *http_response(char *s) {
  char *e = strstr(s, "\r\n");
  int auth = 0, route = 0;
  if (e) {
    *e = 0;
    char *space = strchr(s, ' ');
    if (space && !strncmp(s, "GET ", 4)) {
      char *end = strchr(space + 1, ' ');
      if (end && (!strcmp(end, " HTTP/1.1") || !strcmp(end, " HTTP/1.0"))) {
        *end = 0;
        char *q = strchr(space + 1, '?');
        if (q) {
          *q++ = 0;
          if (!strncmp(q, "key=", 4))
            auth = same_secret(q + 4, strlen(q + 4));
        }
        route = !strcmp(space + 1, "/api/nodes");
      }
    }
    char *line = e + 2;
    while (*line) {
      char *next = strstr(line, "\r\n");
      if (!next)
        break;
      *next = 0;
      if (!strncasecmp(line, "Authorization:", 14)) {
        char *v = line + 14;
        while (*v == ' ' || *v == '\t')
          v++;
        if (!strncmp(v, "Bearer ", 7))
          auth |= same_secret(v + 7, strlen(v + 7));
      }
      line = next + 2;
    }
  }
  Buffer b = buffer();
  if (route && auth) {
    char *json = nodes_json(NULL);
    add(&b,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
        "%zu\r\nConnection: close\r\n\r\n%s",
        strlen(json), json);
    free(json);
  } else
    add(&b, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: "
            "close\r\n\r\n");
  return b.s;
}
static void discard(Client *c) {
#if ADMIN
  if (c->admin) admin_free(c->admin);
#endif
  close(c->fd);
  free(c->in);
  free(c->out);
  memset(c, 0, sizeof(*c));
  c->fd = -1;
}
static void send_push(const char *address, const char *json, const uint8_t transport_key[32]) {
  int fd = endpoint(address, "127.0.0.1", 0);
  if (fd < 0)
    return;
  size_t len = 0;
  uint8_t *p = frame(json, &len, transport_key);
  double deadline = monotime() + 1;
  size_t off = 0;
  while (p && off < len && monotime() < deadline) {
    struct pollfd pf = {fd, POLLOUT, 0};
    if (poll(&pf, 1, 100) <= 0)
      continue;
    ssize_t n = send(fd, p + off, len - off, 0);
    if (n > 0)
      off += (size_t)n;
    else if (errno != EAGAIN && errno != EINTR)
      break;
  }
  free(p);
  close(fd);
}
static void push(void) {
  char *s = snapshot(display);
  if (upstream) {
    Buffer b = buffer();
    add(&b, "{\"op\":\"push\",\"ts\":%lld,\"node\":%s}", (long long)time(NULL), s);
    send_push(upstream, b.s, key);
    free(b.s);
  }
  if (group_upstream) {
    char *json = group_push_json(s);
    if (json) { send_push(group_upstream, json, relay_key); free(json); }
  }
  free(s);
}
static int relay_http_header(Client *c) {
  char *end = strstr((char *)c->in, "\r\n\r\n");
  if (!end) return c->have == c->want ? -1 : 0;
  c->body = (size_t)(end - (char *)c->in) + 4;
  if (c->body > 8192) return -1;
  char *copy = strndup((char *)c->in, c->body);
  if (!copy) return -1;
  char *save, *line = strtok_r(copy, "\r\n", &save);
  int route = line && (!strcmp(line, "POST /api/relay HTTP/1.1") || !strcmp(line, "POST /api/relay HTTP/1.0"));
  size_t length = 0;
  int lengths = 0, content_type = 0;
  while ((line = strtok_r(NULL, "\r\n", &save))) {
    if (!strncasecmp(line, "Content-Length:", 15)) {
      char *value = line + 15;
      while (*value == ' ' || *value == '\t') value++;
      char *tail;
      unsigned long n = strtoul(value, &tail, 10);
      if (!isdigit((unsigned char)*value) || *tail || n < 33 || n > MAX_FRAME + 32) route = 0;
      length = (size_t)n;
      lengths++;
    } else if (!strncasecmp(line, "Transfer-Encoding:", 18)) route = 0;
    else if (!strncasecmp(line, "Content-Type:", 13)) {
      char *value = line + 13;
      while (*value == ' ' || *value == '\t') value++;
      content_type = !strcasecmp(value, "application/octet-stream");
    }
  }
  free(copy);
  if (!route || lengths != 1 || !content_type || c->have > c->body + length) return -1;
  c->want = c->body + length;
  uint8_t *p = realloc(c->in, c->want + 1);
  if (!p) return -1;
  c->in = p;
  return 1;
}
static void http_not_found(Client *c) {
  c->out = (uint8_t *)strdup("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
  if (c->out) c->outlen = strlen((char *)c->out);
  else discard(c);
}
static void option(const char *k, const char *v) {
#if ADMIN
  if (!strcmp(k, "admin_keys") || !strcmp(k, "A")) { admin_keys_text = strdup(v); return; }
#endif
  if (!strcmp(k, "relay_listen") || !strcmp(k, "S")) relay_addr = strdup(v);
  else if (!strcmp(k, "token") || !strcmp(k, "T")) relay_token = strdup(v);
  else if (!strcmp(k, "group_secret") || !strcmp(k, "G")) group_secret = strdup(v);
  else if (!strcmp(k, "relay_upstream") || !strcmp(k, "R")) group_upstream = strdup(v);
  else if (!strcmp(k, "secret") || !strcmp(k, "k"))
    secret = strdup(v);
  else if (!strcmp(k, "listen") || !strcmp(k, "l"))
    listen_addr = strdup(v);
  else if (!strcmp(k, "http") || !strcmp(k, "H"))
    http_addr = strdup(v);
  else if (!strcmp(k, "upstream") || !strcmp(k, "u"))
    upstream = strdup(v);
  else if (!strcmp(k, "name") || !strcmp(k, "n"))
    display = strdup(v);
  else if (!strcmp(k, "interval") || !strcmp(k, "i")) {
    char *end;
    long n = strtol(v, &end, 10);
    if (*end || n < 1 || n > 86400) {
      fprintf(stderr, "invalid interval\n");
      exit(2);
    }
    interval = (int)n;
  } else {
    fprintf(stderr, "unknown config key: %s\n", k);
    exit(2);
  }
}
static void config(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) {
    perror(path);
    exit(2);
  }
  char line[4096];
  while (fgets(line, sizeof(line), f)) {
    char *p = line;
    while (isspace((unsigned char)*p))
      p++;
    if (!*p || *p == '#')
      continue;
    char *eqp = strchr(p, '=');
    if (!eqp) {
      fprintf(stderr, "invalid config\n");
      exit(2);
    }
    *eqp++ = 0;
    char *e = p + strlen(p);
    while (e > p && isspace((unsigned char)e[-1]))
      *--e = 0;
    while (isspace((unsigned char)*eqp))
      eqp++;
    e = eqp + strlen(eqp);
    while (e > eqp && isspace((unsigned char)e[-1]))
      *--e = 0;
    option(p, eqp);
  }
  fclose(f);
}
static void usage(void) {
#if PAIR
  puts("Temporary pairing: -P (-l addr:port -k SECRET | -R relay:port -T TOKEN -G GROUP) [-n NAME] [-W seconds (default 600)] [-Q ascii]");
#else
  puts("Pairing unavailable (PAIR=0); use install.sh pair for lite installations.");
#endif
  puts("npulse 0.1.0\nUsage: npulse [-k SECRET] [-l [addr:]port] [-H "
       "[addr:]port]\n              [-u host:port] [-i seconds] [-n NAME] [-c "
       "config] [-h]\nDirect listen defaults to 0.0.0.0; HTTP defaults to "
       "127.0.0.1.\nIPv6 endpoints use [address]:port. Config keys: secret, "
       "listen, http,\nupstream, interval, name (key=value). CLI overrides "
       "config.");
  puts("Shared E2E relay: -S [addr:]port -T TOKEN [-H [addr:]port]\n"
       "Publish E2E snapshots: -R host:port -T TOKEN [-G SECRET (default -k)]\n"
       "HTTP-only relay: -H [addr:]port -T TOKEN (without -k).\n"
       "Config keys: relay_listen, token, group_secret, relay_upstream (or S/T/G/R).");
#if ADMIN
  puts("Admin (disabled by default): -A ED25519_PUBKEY[,PUBKEY...] (requires -l or -R).\nConfig key: admin_keys. Session idle timeout: 600 seconds.");
#endif
}
int main(int argc, char **argv) {
  int opt, pairing = 0, qr_ascii = 0;
  unsigned pair_timeout = 600;
  for (int i = 1; i < argc; i++)
    if (!strcmp(argv[i], "-h")) {
      usage();
      return 0;
    }
  while ((opt = getopt(argc, argv, "Pk:l:H:u:i:n:c:S:T:G:R:W:Q:" ADMIN_FLAGS "h")) != -1)
    if (opt == 'c')
      config(optarg);
  optind = 1;
  while ((opt = getopt(argc, argv, "Pk:l:H:u:i:n:c:S:T:G:R:W:Q:" ADMIN_FLAGS "h")) != -1) {
    if (opt == 'c')
      continue;
    if (opt == '?')
      return 2;
    if (opt == 'P') { pairing = 1; continue; }
    if (opt == 'Q') { if (strcmp(optarg, "ascii")) { fprintf(stderr, "-Q accepts ascii\n"); return 2; } qr_ascii = 1; continue; }
    if (opt == 'W') {
      char *end; errno = 0; unsigned long value = strtoul(optarg, &end, 10);
      if (errno || *end || !value || value > 86400) { fprintf(stderr, "invalid pairing timeout (1..86400)\n"); return 2; }
      pair_timeout = (unsigned)value; continue;
    }
    char k[2] = {(char)opt, 0};
    option(k, optarg);
  }
  if (pairing) {
#if PAIR
    if (optind != argc || http_addr || upstream || relay_addr ||
        (group_upstream ? listen_addr || !relay_token || !*relay_token || !group_secret || !*group_secret : !listen_addr || !secret || !*secret)) {
      usage(); return 2;
    }
    if (group_upstream) { uint8_t hash[64]; crypto_sha512(hash, (const uint8_t *)relay_token, strlen(relay_token)); memcpy(relay_key, hash, 32); crypto_wipe(hash, sizeof(hash)); }
    metrics_init(display);
    if (!display) display = hostname_buf;
    return pair_run(pair_timeout, qr_ascii);
#else
    (void)pair_timeout; (void)qr_ascii;
    fprintf(stderr, "此构建不支持配对（PAIR=0）；lite 版请运行 install.sh pair，临时使用完整版配对。\n");
    return 2;
#endif
  }
  int relay_http = relay_addr || (relay_token && !secret);
  int collect = listen_addr || upstream || group_upstream || (http_addr && !relay_http);
  if (!group_secret) group_secret = secret;
  if (optind != argc || (!listen_addr && !http_addr && !upstream && !relay_addr && !group_upstream) ||
      ((listen_addr || upstream || (http_addr && !relay_http)) && (!secret || !*secret)) ||
      ((relay_addr || relay_http || group_upstream) && (!relay_token || !*relay_token)) ||
      (group_upstream && (!group_secret || !*group_secret))) {
    usage();
    return 2;
  }
  uint8_t hash[64];
  if (secret) {
    crypto_sha512(hash, (const uint8_t *)secret, strlen(secret));
    memcpy(key, hash, 32);
  }
  if (relay_token) {
    crypto_sha512(hash, (const uint8_t *)relay_token, strlen(relay_token));
    memcpy(relay_key, hash, 32);
  }
  if (group_upstream) group_init();
#if ADMIN
  if (admin_init()) { fprintf(stderr, "invalid admin_keys or missing -l/-R\n"); return 2; }
  signal(SIGCHLD, admin_sigchld);
#endif
  crypto_wipe(hash, sizeof(hash));
  if (collect) {
    metrics_init(display);
    if (!display) display = hostname_buf;
    sample();
  }
#if ADMIN || PAIR
  pipe_init();
#endif
  signal(SIGPIPE, SIG_IGN);
  signal(SIGINT, stop);
  signal(SIGTERM, stop);
  int listeners[3] = {-1, -1, -1};
  if (listen_addr)
    listeners[0] = endpoint(listen_addr, "0.0.0.0", 1);
  if (http_addr)
    listeners[1] = endpoint(http_addr, "127.0.0.1", 1);
  if (relay_addr) listeners[2] = endpoint(relay_addr, "0.0.0.0", 1);
  if ((listen_addr && listeners[0] < 0) || (http_addr && listeners[1] < 0) || (relay_addr && listeners[2] < 0)) {
    fprintf(stderr, "cannot listen\n");
    return 1;
  }
  Client clients[CLIENTS];
  memset(clients, 0, sizeof(clients));
  for (int i = 0; i < CLIENTS; i++)
    clients[i].fd = -1;
  double next_sample = monotime() + 1, next_push = monotime();
  while (running) {
#if ADMIN || PAIR
    pipe_tick(monotime());
#endif
    struct pollfd pf[CLIENTS + 3 + ADMIN_POLLS];
    int count = CLIENTS + 3;
#if ADMIN
    int pty_base[CLIENTS];
#endif
    for (int i = 0; i < 3; i++)
      pf[i] = (struct pollfd){listeners[i], POLLIN, 0};
    for (int i = 0; i < CLIENTS; i++) {
      pf[i + 3] =
          (struct pollfd){clients[i].fd, clients[i].out ? POLLOUT : POLLIN, 0};
#if ADMIN
      Admin *a = clients[i].admin;
      pty_base[i] = count;
      if (a && !clients[i].out) {
        pf[i + 3].events = admin_events(a);
        admin_poll(a, pf + count);
        count += 4;
      }
#endif
    }
#if ADMIN || PAIR
    int pipe_base = count;
    count += pipe_poll(pf + count);
#endif
    poll(pf, (nfds_t)count, 100);
    double now = monotime();
#if ADMIN || PAIR
    pipe_io(pf + pipe_base);
#endif
#if ADMIN
    admin_tick(now);
    int accepted;
    while ((accepted = probe_take()) >= 0) {
      Client *c = NULL;
      for (int i = 0; i < CLIENTS; i++) if (clients[i].fd < 0) { c = &clients[i]; break; }
      if (!c) { close(accepted); continue; }
      c->fd = accepted; c->pipe_hello = 1; c->want = 4;
      c->in = calloc(5, 1); c->deadline = monotime() + 5;
      if (!c->in) discard(c);
    }
#endif
    if (collect && now >= next_sample) {
      sample();
      next_sample = now + 1;
    }
    if ((upstream || group_upstream) && now >= next_push) {
      push();
      next_push = now + interval;
    }
    for (int i = 0; i < 3; i++)
      if (pf[i].revents & POLLIN) {
        int fd = accept(listeners[i], NULL, NULL);
        if (fd >= 0) {
          int slot = -1;
          for (int j = 0; j < CLIENTS; j++)
            if (clients[j].fd < 0) {
              slot = j;
              break;
            }
          if (slot < 0)
            close(fd);
          else {
            fcntl(fd, F_SETFL, O_NONBLOCK);
#if ADMIN
            fcntl(fd, F_SETFD, FD_CLOEXEC);
#endif
            Client *c = &clients[slot];
            c->fd = fd;
            c->http = i == 1;
            c->relay = i == 2 || (i == 1 && relay_http);
            c->want = c->http ? 8192 : 4;
            c->in = calloc(c->want + 1, 1);
            c->deadline = monotime() + 5;
            if (!c->in)
              discard(c);
          }
        }
      }
    for (int i = 0; i < CLIENTS; i++) {
      Client *c = &clients[i];
      if (c->fd < 0)
        continue;
#if ADMIN
      if (c->admin && !c->out) {
        if (admin_io(c->admin, c->fd, pf[i + 3].revents, pf + pty_base[i])) discard(c);
        continue;
      }
#endif
      if (monotime() > c->deadline ||
          (pf[i + 3].revents & (POLLERR | POLLNVAL))) {
        discard(c);
        continue;
      }
      if (c->out) {
        if (pf[i + 3].revents & POLLOUT) {
          ssize_t n = send(c->fd, c->out + c->sent, c->outlen - c->sent, 0);
          if (n > 0) {
            c->sent += (size_t)n;
            if (c->sent == c->outlen) {
#if ADMIN
              if (c->admin) {
                free(c->out); c->out = NULL;
                free(c->in); c->in = NULL;
              } else
#endif
                discard(c);
            }
          } else if (n == 0 || (errno != EAGAIN && errno != EINTR))
            discard(c);
        }
        continue;
      }
      if (!(pf[i + 3].revents & (POLLIN | POLLHUP)))
        continue;
      ssize_t n = recv(c->fd, c->in + c->have, c->want - c->have, 0);
      if (n <= 0) {
        if (n == 0 || (errno != EAGAIN && errno != EINTR))
          discard(c);
        continue;
      }
      c->have += (size_t)n;
      c->in[c->have] = 0;
      if (!c->http && c->want == 4 && c->have == 4) {
        uint32_t be;
        memcpy(&be, c->in, 4);
        size_t len = ntohl(be);
        if (!len || len > MAX_FRAME) {
          discard(c);
          continue;
        }
        c->want = len + 32;
#if ADMIN
        if (c->pipe_hello) c->want = len + 4;
#endif
        uint8_t *p = realloc(c->in, c->want + 1);
        if (!p) {
          discard(c);
          continue;
        }
        c->in = p;
        continue;
      }
      if (c->http && c->relay && !c->body) {
        int result = relay_http_header(c);
        if (result < 0) { http_not_found(c); continue; }
        if (!result) continue;
      }
      int ready = c->http && !c->relay ? strstr((char *)c->in, "\r\n\r\n") != NULL
                          : c->have == c->want;
      if (ready) {
        if (c->http && c->relay) {
          char *json = request(c->in + c->body, c->have - c->body, 1, NULL);
          if (!json) { discard(c); continue; }
          size_t len = 0;
          uint8_t *body = frame(json, &len, relay_key);
          free(json);
          if (!body) { discard(c); continue; }
          Buffer header = buffer();
          add(&header, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", len);
          c->outlen = header.n + len;
          c->out = malloc(c->outlen);
          if (c->out) { memcpy(c->out, header.s, header.n); memcpy(c->out + header.n, body, len); }
          free(header.s); free(body);
          if (!c->out) discard(c);
          continue;
        }
        char *s = NULL;
#if ADMIN
        if (c->pipe_hello) {
          Json j; long long stamp;
          if (!memchr(c->in + 4, 0, c->have - 4) && !parse(&j, (char *)c->in + 4) && !admin_number(&j, "ts", &stamp))
            s = admin_hello(&j, stamp, time(NULL), &c->admin, group_secret);
        } else
#endif
          s = c->http ? http_response((char *)c->in) : request(c->in, c->have, c->relay, c);
        if (c->taken) { c->fd = -1; discard(c); continue; }
        if (!s) {
          discard(c);
          continue;
        }
        if (c->http) {
          c->out = (uint8_t *)s;
          c->outlen = strlen(s);
        } else {
#if ADMIN
          if (c->pipe_hello) {
            size_t len = strlen(s); uint32_t be = htonl((uint32_t)len);
            c->out = malloc(len + 4); c->outlen = len + 4;
            if (c->out) { memcpy(c->out, &be, 4); memcpy(c->out + 4, s, len); }
          } else
#endif
          c->out = frame(s, &c->outlen, c->relay ? relay_key : key);
          free(s);
          if (!c->out)
            discard(c);
        }
      } else if (c->have == c->want)
        discard(c);
    }
  }
  for (int i = 0; i < CLIENTS; i++)
    if (clients[i].fd >= 0)
      discard(&clients[i]);
  for (int i = 0; i < 3; i++)
    if (listeners[i] >= 0)
      close(listeners[i]);
#if ADMIN || PAIR
  pipe_shutdown();
#endif
#if ADMIN
  admin_shutdown();
#endif
  return 0;
}
