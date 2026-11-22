#define _GNU_SOURCE
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
#define CLIENTS 32
static uint8_t key[32];
static const char *secret, *display, *listen_addr, *http_addr, *upstream;
static int interval = 5;
static volatile sig_atomic_t running = 1;
static void stop(int sig) {
  (void)sig;
  running = 0;
}
typedef struct {
  char *json, *id;
  time_t seen;
} Node;
static Node nodes[64];
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
static int endpoint(const char *s, const char *def, int server) {
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
  hints.ai_flags = server ? AI_PASSIVE : 0;
  if (getaddrinfo(*host ? host : NULL, port, &hints, &res))
    return -1;
  int fd = -1;
  for (struct addrinfo *a = res; a; a = a->ai_next) {
    fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    if (fd < 0)
      continue;
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (server) {
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
static uint8_t *frame(const char *s, size_t *size) {
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
  crypto_aead_init_ietf(&ctx, key, p + 4);
  crypto_aead_write(&ctx, p + 16, p + 16 + n, p, 4, (const uint8_t *)s, n);
  crypto_wipe(&ctx, sizeof(ctx));
  *size = n + 32;
  return p;
}
static char *nodes_json(void) {
  Buffer b = buffer();
  add(&b, "{\"ok\":true,\"nodes\":[");
  int comma = 0;
  if (listen_addr) {
    char *s = snapshot(display);
    s[strlen(s) - 1] = 0;
    add(&b, "%s,\"relay\":false}", s);
    free(s);
    comma = 1;
  }
  time_t now = time(NULL);
  for (int i = 0; i < 64; i++) {
    Node *n = &nodes[i];
    if (n->json && now - n->seen > 600) {
      free(n->json);
      free(n->id);
      memset(n, 0, sizeof(*n));
    }
    if (n->json)
      add(&b, "%s%.*s,\"relay\":true,\"last_seen\":%lld}", comma++ ? "," : "",
          (int)strlen(n->json) - 1, n->json, (long long)n->seen);
  }
  add(&b, "]}");
  return b.s;
}
static char *request(uint8_t *p, size_t total) {
  uint32_t be;
  memcpy(&be, p, 4);
  size_t n = ntohl(be);
  if (total != n + 32)
    return NULL;
  char *plain = malloc(n + 1);
  if (!plain)
    return NULL;
  crypto_aead_ctx ctx;
  crypto_aead_init_ietf(&ctx, key, p + 4);
  int bad =
      crypto_aead_read(&ctx, (uint8_t *)plain, p + n + 16, p, 4, p + 16, n);
  crypto_wipe(&ctx, sizeof(ctx));
  if (bad) {
    free(plain);
    return NULL;
  }
  plain[n] = 0;
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
  if (eq(&j, op, "get"))
    response = nodes_json();
  else if (eq(&j, op, "push")) {
    int obj = field(&j, 0, "node"), id = field(&j, obj, "id");
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
    for (int i = 0; i < 64; i++)
      if (nodes[i].id && !strcmp(nodes[i].id, ident)) {
        slot = i;
        break;
      }
    if (slot < 0)
      for (int i = 0; i < 64; i++)
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
      if (end && !strcmp(end, " HTTP/1.1")) {
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
    char *json = nodes_json();
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
typedef struct {
  int fd, http;
  uint8_t *in, *out;
  size_t have, want, sent, outlen;
  double deadline;
} Client;
static void discard(Client *c) {
  close(c->fd);
  free(c->in);
  free(c->out);
  memset(c, 0, sizeof(*c));
  c->fd = -1;
}
static void push(void) {
  int fd = endpoint(upstream, "127.0.0.1", 0);
  if (fd < 0)
    return;
  char *s = snapshot(display);
  Buffer b = buffer();
  add(&b, "{\"op\":\"push\",\"ts\":%lld,\"node\":%s}", (long long)time(NULL),
      s);
  free(s);
  size_t len = 0;
  uint8_t *p = frame(b.s, &len);
  free(b.s);
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
static void option(const char *k, const char *v) {
  if (!strcmp(k, "secret") || !strcmp(k, "k"))
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
  puts("npulse 0.1.0\nUsage: npulse -k SECRET [-l [addr:]port] [-H "
       "[addr:]port]\n              [-u host:port] [-i seconds] [-n NAME] [-c "
       "config] [-h]\nDirect listen defaults to 0.0.0.0; HTTP defaults to "
       "127.0.0.1.\nIPv6 endpoints use [address]:port. Config keys: secret, "
       "listen, http,\nupstream, interval, name (key=value). CLI overrides "
       "config.");
}
int main(int argc, char **argv) {
  int opt;
  for (int i = 1; i < argc; i++)
    if (!strcmp(argv[i], "-h")) {
      usage();
      return 0;
    }
  while ((opt = getopt(argc, argv, "k:l:H:u:i:n:c:h")) != -1)
    if (opt == 'c')
      config(optarg);
  optind = 1;
  while ((opt = getopt(argc, argv, "k:l:H:u:i:n:c:h")) != -1) {
    if (opt == 'c')
      continue;
    if (opt == '?')
      return 2;
    char k[2] = {(char)opt, 0};
    option(k, optarg);
  }
  if (optind != argc || !secret || !*secret ||
      (!listen_addr && !http_addr && !upstream)) {
    usage();
    return 2;
  }
  uint8_t hash[64];
  crypto_sha512(hash, (const uint8_t *)secret, strlen(secret));
  memcpy(key, hash, 32);
  crypto_wipe(hash, sizeof(hash));
  metrics_init();
  if (!display)
    display = hostname_buf;
  sample();
  signal(SIGPIPE, SIG_IGN);
  signal(SIGINT, stop);
  signal(SIGTERM, stop);
  int listeners[2] = {-1, -1};
  if (listen_addr)
    listeners[0] = endpoint(listen_addr, "0.0.0.0", 1);
  if (http_addr)
    listeners[1] = endpoint(http_addr, "127.0.0.1", 1);
  if ((listen_addr && listeners[0] < 0) || (http_addr && listeners[1] < 0)) {
    fprintf(stderr, "cannot listen\n");
    return 1;
  }
  Client clients[CLIENTS];
  memset(clients, 0, sizeof(clients));
  for (int i = 0; i < CLIENTS; i++)
    clients[i].fd = -1;
  double next_sample = monotime() + 1, next_push = monotime();
  while (running) {
    struct pollfd pf[CLIENTS + 2];
    for (int i = 0; i < 2; i++)
      pf[i] = (struct pollfd){listeners[i], POLLIN, 0};
    for (int i = 0; i < CLIENTS; i++)
      pf[i + 2] =
          (struct pollfd){clients[i].fd, clients[i].out ? POLLOUT : POLLIN, 0};
    poll(pf, CLIENTS + 2, 100);
    double now = monotime();
    if (now >= next_sample) {
      sample();
      next_sample = now + 1;
    }
    if (upstream && now >= next_push) {
      push();
      next_push = now + interval;
    }
    for (int i = 0; i < 2; i++)
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
            Client *c = &clients[slot];
            c->fd = fd;
            c->http = i;
            c->want = i ? 8192 : 4;
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
      if (monotime() > c->deadline ||
          (pf[i + 2].revents & (POLLERR | POLLNVAL))) {
        discard(c);
        continue;
      }
      if (c->out) {
        if (pf[i + 2].revents & POLLOUT) {
          ssize_t n = send(c->fd, c->out + c->sent, c->outlen - c->sent, 0);
          if (n > 0) {
            c->sent += (size_t)n;
            if (c->sent == c->outlen)
              discard(c);
          } else if (n == 0 || (errno != EAGAIN && errno != EINTR))
            discard(c);
        }
        continue;
      }
      if (!(pf[i + 2].revents & (POLLIN | POLLHUP)))
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
        uint8_t *p = realloc(c->in, c->want + 1);
        if (!p) {
          discard(c);
          continue;
        }
        c->in = p;
        continue;
      }
      int ready = c->http ? strstr((char *)c->in, "\r\n\r\n") != NULL
                          : c->have == c->want;
      if (ready) {
        char *s =
            c->http ? http_response((char *)c->in) : request(c->in, c->have);
        if (!s) {
          discard(c);
          continue;
        }
        if (c->http) {
          c->out = (uint8_t *)s;
          c->outlen = strlen(s);
        } else {
          c->out = frame(s, &c->outlen);
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
  for (int i = 0; i < 2; i++)
    if (listeners[i] >= 0)
      close(listeners[i]);
  return 0;
}
