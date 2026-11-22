#ifndef NP_PAIRING_H
#define NP_PAIRING_H
#include <termios.h>
#include <sys/select.h>
#ifndef QR
#define QR 1
#endif
#if QR
#include "vendor/qrcodegen.h"
#endif
#define PAIR_FRAME 4096
static void pair_derive(uint8_t out[64], const uint8_t shared[32], const uint8_t client[32], const uint8_t probe[32], const uint8_t *psk) {
  crypto_sha512_ctx h; crypto_sha512_init(&h);
  crypto_sha512_update(&h, (const uint8_t *)"npulse-pair", 11);
  crypto_sha512_update(&h, shared, 32); crypto_sha512_update(&h, client, 32); crypto_sha512_update(&h, probe, 32);
  if (psk) crypto_sha512_update(&h, psk, 16);
  crypto_sha512_final(&h, out);
}
static void pair_urlencode(Buffer *b, const char *text) {
  for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
    if ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || strchr("-._~", *p)) add(b, "%c", *p);
    else add(b, "%%%02X", *p);
  }
}
static void pair_qr(FILE *tty, const char *url, int ascii) {
#if QR
  uint8_t qr[qrcodegen_BUFFER_LEN_MAX], data[qrcodegen_BUFFER_LEN_MAX];
  size_t n = strlen(url);
  if (n <= sizeof(data)) {
    memcpy(data, url, n);
    if (qrcodegen_encodeBinary(data, n, qr, qrcodegen_Ecc_MEDIUM, qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, false)) {
      int size = qrcodegen_getSize(qr);
      for (int y = -4; y < size + 4; y += ascii ? 1 : 2) {
        if (!ascii) fputs("\033[30;107m", tty);
        for (int x = -4; x < size + 4; x++) {
          int upper = qrcodegen_getModule(qr, x, y), lower = qrcodegen_getModule(qr, x, y + 1);
          fputs(ascii ? (upper ? "##" : "  ") : upper ? (lower ? "█" : "▀") : (lower ? "▄" : " "), tty);
        }
        fputs(ascii ? "\n" : "\033[0m\n", tty);
      }
    } else fputs("二维码内容过长，请使用下方链接或手动配对。\n", tty);
  }
  crypto_wipe(data, sizeof(data)); crypto_wipe(qr, sizeof(qr));
#else
  (void)ascii;
#endif
  fprintf(tty, "%s\n扫码仅填写连接信息，仍须核对双方图案和数字。请勿分享此链接。\n", url); fflush(tty);
}
static void pair_host(char out[256]) {
  const char *s = listen_addr, *end = strrchr(s, ':');
  if (*s == '[') { s++; end = strchr(s, ']'); }
  if (end && end - s < 256) { memcpy(out, s, (size_t)(end - s)); out[end - s] = 0; }
  else snprintf(out, 256, "0.0.0.0");
  if (strcmp(out, "0.0.0.0") && strcmp(out, "::") && *out) return;
  int family = strchr(out, ':') ? AF_INET6 : AF_INET;
  struct ifaddrs *ifs;
  if (getifaddrs(&ifs)) return;
  for (struct ifaddrs *p = ifs; p; p = p->ifa_next) {
    if (!p->ifa_addr || p->ifa_addr->sa_family != family || !(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
    const void *address = family == AF_INET ? (const void *)&((struct sockaddr_in *)p->ifa_addr)->sin_addr : (const void *)&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
    if (family == AF_INET6 && IN6_IS_ADDR_LINKLOCAL((const struct in6_addr *)address)) continue;
    if (inet_ntop(family, address, out, 256)) break;
  }
  freeifaddrs(ifs);
}
static void pair_hash(uint8_t out[64], const char *domain, const void *a, size_t na, const void *b, size_t nb, const void *c, size_t nc) {
  crypto_sha512_ctx h; crypto_sha512_init(&h);
  crypto_sha512_update(&h, (const uint8_t *)domain, strlen(domain));
  if (na) crypto_sha512_update(&h, a, na);
  if (nb) crypto_sha512_update(&h, b, nb);
  if (nc) crypto_sha512_update(&h, c, nc);
  crypto_sha512_final(&h, out);
}
static void pair_art(char out[221], const uint8_t sas[16]) {
  static const char symbols[] = " .o+=*BOX@%&#/^SE";
  unsigned char cells[9][17] = {{0}};
  int x = 8, y = 4;
  for (int i = 0; i < 16; i++) for (int j = 0; j < 8; j += 2) {
    x += sas[i] & (1 << j) ? 1 : -1;
    y += sas[i] & (2 << j) ? 1 : -1;
    if (x < 0) x = 0;
    if (x > 16) x = 16;
    if (y < 0) y = 0;
    if (y > 8) y = 8;
    if (cells[y][x] < 14) cells[y][x]++;
  }
  cells[4][8] = 15; cells[y][x] = 16;
  char *p = out;
  memcpy(p, "+---[NodePulse]---+\n", 20); p += 20;
  for (y = 0; y < 9; y++) {
    *p++ = '|';
    for (x = 0; x < 17; x++) *p++ = symbols[cells[y][x]];
    *p++ = '|'; *p++ = '\n';
  }
  memcpy(p, "+-----[PAIR]------+\n", 20); p[20] = 0;
}
static int pair_io(int fd, void *data, size_t n, int writing, double deadline) {
  size_t off = 0;
  while (off < n && running && monotime() < deadline) {
    struct pollfd pf = {fd, writing ? POLLOUT : POLLIN, 0};
    int ready = poll(&pf, 1, 100);
    if (ready < 0 && errno != EINTR) return -1;
    if (ready <= 0) continue;
    ssize_t got = writing ? send(fd, (char *)data + off, n - off, 0) : read(fd, (char *)data + off, n - off);
    if (got > 0) off += (size_t)got;
    else if (!got || (errno != EAGAIN && errno != EINTR)) return -1;
  }
  return off == n ? 0 : -1;
}
static int pair_send(int fd, const char *json, const uint8_t *key, uint64_t *seq, double deadline) {
  size_t n = strlen(json);
  if (!n || n > PAIR_FRAME) return -1;
  uint8_t frame[PAIR_FRAME + 20];
  if (key) {
    if (session_seal(frame, key, seq, json, n)) return -1;
  } else {
    uint32_t be = htonl((uint32_t)n); memcpy(frame, &be, 4); memcpy(frame + 4, json, n);
  }
  return pair_io(fd, frame, n + (key ? 20 : 4), 1, deadline);
}
static int pair_receive(int fd, uint8_t frame[PAIR_FRAME + 21], Json *j, const uint8_t *key, uint64_t *seq, double deadline) {
  if (pair_io(fd, frame, 4, 0, deadline)) return -1;
  uint32_t be; memcpy(&be, frame, 4); size_t n = ntohl(be);
  if (!n || n > PAIR_FRAME || pair_io(fd, frame + 4, n + (key ? 16 : 0), 0, deadline)) return -1;
  if (key && session_open(frame, n + 20, key, seq) < 0) return -1;
  if (memchr(frame + 4, 0, n)) return -1;
  frame[4 + n] = 0;
  return parse(j, (char *)frame + 4);
}
static int pair_attempt(int fd, int input, FILE *tty, double deadline, const char *port, const uint8_t psk[16], int relay) {
  uint8_t frame[PAIR_FRAME + 21], commit[32], client[32], sk[32] = {0}, pub[32], shared[32] = {0}, k[64] = {0}, h[64], zero[32] = {0};
  uint64_t rx = 0, tx = 0;
  Json j; int result = -1;
  if (pair_receive(fd, frame, &j, NULL, NULL, deadline) || !eq(&j, field(&j, 0, "op"), "pair")) goto done;
  int version = field(&j, 0, "v");
  if (version < 0 || j.t[version].type != '1' || j.t[version].end - j.t[version].start != 1) goto done;
  int flag = field(&j, 0, "psk"), use_psk = 0;
  if (flag >= 0) {
    if (j.t[flag].type == 't' && j.t[flag].end - j.t[flag].start == 4) use_psk = 1;
    else if (j.t[flag].type != 'f' || j.t[flag].end - j.t[flag].start != 5) goto done;
  }
  char *text = string(&j, field(&j, 0, "commit"));
  int bad = hex_decode(commit, text, 32); free(text);
  if (bad || random_bytes(sk, 32)) goto done;
  crypto_x25519_public_key(pub, sk);
  char hex[65]; hex_encode(hex, pub, 32);
  Buffer b = buffer(); add(&b, "{\"epk\":\"%s\"}", hex);
  bad = pair_send(fd, b.s, NULL, NULL, deadline); free(b.s);
  if (bad || pair_receive(fd, frame, &j, NULL, NULL, deadline)) goto done;
  text = string(&j, field(&j, 0, "epk")); bad = hex_decode(client, text, 32); free(text);
  if (bad) goto done;
  pair_hash(h, "npulse-pair-commit", client, 32, NULL, 0, NULL, 0);
  if (crypto_verify32(commit, h)) goto done;
  crypto_x25519(shared, sk, client);
  if (!crypto_verify32(shared, zero)) goto done;
  pair_derive(k, shared, client, pub, use_psk ? psk : NULL);
  crypto_wipe(sk, sizeof(sk)); crypto_wipe(shared, sizeof(shared));
  pair_hash(h, "npulse-pair-sas", k, 64, NULL, 0, NULL, 0);
  char art[221]; pair_art(art, h);
  uint32_t code = ((uint32_t)h[0] << 24 | (uint32_t)h[1] << 16 | (uint32_t)h[2] << 8 | h[3]) % 1000000;
  tcflush(input, TCIFLUSH);
  fprintf(tty, "\n%s\n%03u %03u\n手机上显示的图案和数字是否一致？[y/N] ", art, code / 1000, code % 1000); fflush(tty);
  if (pair_receive(fd, frame, &j, k, &rx, deadline)) goto done;
  if (eq(&j, field(&j, 0, "op"), "reject")) {
    pair_send(fd, "{\"ok\":false}", k + 32, &tx, deadline); result = -2; goto done;
  }
  if (!eq(&j, field(&j, 0, "op"), "confirm")) goto done;
  char *admin = string(&j, field(&j, 0, "admin_pk")); uint8_t apk[32];
  if (admin && hex_decode(apk, admin, 32)) { free(admin); goto done; }
  if (admin && ADMIN) { fprintf(tty, "\n警告：手机请求 root 级远程管理授权。仅在确认图案和数字一致后输入 y： "); fflush(tty); }
  char answer[64]; size_t used = 0;
  int flags = fcntl(input, F_GETFL);
  if (input >= FD_SETSIZE || flags < 0 || fcntl(input, F_SETFL, flags | O_NONBLOCK)) { free(admin); goto done; }
  while (running && monotime() < deadline && used + 1 < sizeof(answer)) {
    fd_set reads; FD_ZERO(&reads); FD_SET(input, &reads); struct timeval wait = {0, 100000};
    if (select(input + 1, &reads, NULL, NULL, &wait) <= 0) continue;
    char c; ssize_t n = read(input, &c, 1);
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
    if (n != 1) break;
    if (c == '\n' || c == '\r') break;
    answer[used++] = c;
  }
  if (fcntl(input, F_SETFL, flags)) used = 0;
  answer[used] = 0;
  if (used != 1 || (answer[0] != 'y' && answer[0] != 'Y') || monotime() >= deadline || !running) {
    pair_send(fd, "{\"ok\":false}", k + 32, &tx, deadline); free(admin); result = -2; goto done;
  }
  b = buffer(); add(&b, relay ? "{\"ok\":true,\"mode\":\"relay\",\"group\":" : "{\"ok\":true,\"key\":"); quote(&b, relay ? group_secret : secret);
  add(&b, ",\"node\":"); quote(&b, node_id); add(&b, ",\"name\":"); quote(&b, display);
  if (!relay) add(&b, ",\"port\":%lu", strtoul(port, NULL, 10));
  add(&b, ",\"admin\":%s}", ADMIN ? "true" : "false");
  bad = pair_send(fd, b.s, k + 32, &tx, deadline); crypto_wipe(b.s, b.n); free(b.s);
  if (!bad) {
    if (admin && ADMIN) printf("admin_pk=%s\n", admin);
    fprintf(tty, "\n配对成功。\n"); result = 0;
  }
  free(admin);
done:
  crypto_wipe(sk, sizeof(sk)); crypto_wipe(shared, sizeof(shared));
  crypto_wipe(k, sizeof(k)); crypto_wipe(frame, sizeof(frame)); crypto_wipe(h, sizeof(h));
  return result;
}
static char *pair_outer(int fd, double deadline) {
  uint8_t data[PAIR_FRAME + 32];
  if (pair_io(fd, data, 4, 0, deadline)) return NULL;
  uint32_t be; memcpy(&be, data, 4); size_t n = ntohl(be);
  if (!n || n > PAIR_FRAME || pair_io(fd, data + 4, n + 28, 0, deadline)) return NULL;
  return unframe(data, n + 32, relay_key);
}
static int pair_relay_open(FILE *tty, double deadline, const char *psk, int ascii) {
  int fd = endpoint(group_upstream, "127.0.0.1", 0);
  if (fd < 0) return -1;
  uint8_t rid[16]; char hex[33];
  if (random_bytes(rid, 16)) { close(fd); return -1; }
  hex_encode(hex, rid, 16);
  Buffer b = buffer(); add(&b, "{\"op\":\"ppair\",\"v\":1,\"ts\":%lld,\"rid\":\"%s\"}", (long long)time(NULL), hex);
  size_t size; uint8_t *wire = frame(b.s, &size, relay_key); free(b.s);
  double auth = monotime() + 10; if (auth > deadline) auth = deadline;
  int bad = !wire || pair_io(fd, wire, size, 1, auth); free(wire);
  char *json = bad ? NULL : pair_outer(fd, auth); Json j;
  if (!json || parse(&j, json)) { free(json); close(fd); return -1; }
  char *code = string(&j, field(&j, 0, "code"));
  int ok = field(&j, 0, "ok");
  bad = ok < 0 || j.t[ok].type != 't' || !code || strlen(code) != 9;
  free(json);
  if (!bad) for (int i = 0; i < 9; i++) if (i == 4 ? code[i] != '-' : !strchr("0123456789ABCDEFGHJKMNPQRSTVWXYZ", code[i])) bad = 1;
  if (bad) { free(code); close(fd); return -1; }
  fprintf(tty, "中转地址：%s\n中转配对码：%s\n手机选择「中转配对」，填写地址、中转密码与配对码。\n", group_upstream, code);
  b = buffer(); add(&b, "nodepulse://pair?v=1&r="); pair_urlencode(&b, group_upstream);
  add(&b, "&t="); pair_urlencode(&b, relay_token); add(&b, "&c=%s&s=%s", code, psk);
  pair_qr(tty, b.s, ascii); crypto_wipe(b.s, b.n); free(b.s); free(code);
  json = pair_outer(fd, deadline);
  bad = !json || parse(&j, json); if (!bad) { ok = field(&j, 0, "ok"); bad = ok < 0 || j.t[ok].type != 't'; }
  free(json);
  if (bad) { close(fd); return -1; }
  return fd;
}
static int pair_run(unsigned timeout, int ascii) {
  signal(SIGPIPE, SIG_IGN); signal(SIGINT, stop); signal(SIGTERM, stop);
  int relay = group_upstream != NULL;
  int listener = relay ? -1 : endpoint(listen_addr, "0.0.0.0", 1);
  if (!relay && listener < 0) { fprintf(stderr, "无法监听配对端口\n"); return 1; }
  int input = open("/dev/tty", O_RDWR | O_NOCTTY);
  FILE *tty = input < 0 ? stderr : fdopen(dup(input), "w");
  if (!tty) tty = stderr;
  if (input < 0) input = STDIN_FILENO;
  const char *port = relay ? "0" : strrchr(listen_addr, ':'); port = relay ? "0" : port ? port + 1 : listen_addr;
  double deadline = monotime() + timeout;
  if (relay) fprintf(tty, "临时中转配对窗口：%u 秒。正在连接中转。\n", timeout);
  else fprintf(tty, "临时配对窗口：%u 秒。请在手机上选择直连配对，端口 %s。\n", timeout, port);
  fflush(tty);
  uint8_t psk[16];
  if (random_bytes(psk, sizeof(psk))) { if (listener >= 0) close(listener); if (tty != stderr) fclose(tty); if (input != STDIN_FILENO) close(input); return 1; }
  char *psk_text = base64_encode(psk, 16);
  if (!psk_text) { crypto_wipe(psk, 16); if (listener >= 0) close(listener); if (tty != stderr) fclose(tty); if (input != STDIN_FILENO) close(input); return 1; }
  for (char *p = psk_text; *p; p++) { if (*p == '+') *p = '-'; else if (*p == '/') *p = '_'; else if (*p == '=') { *p = 0; break; } }
  if (!relay) {
    char host[256]; pair_host(host);
    Buffer b = buffer(); add(&b, "nodepulse://pair?v=1&h="); pair_urlencode(&b, host); add(&b, "&p=%lu&s=%s", strtoul(port, NULL, 10), psk_text);
    pair_qr(tty, b.s, ascii); crypto_wipe(b.s, b.n); free(b.s);
  }
  int result = 1;
  for (int attempts = 0; running && monotime() < deadline && attempts < 5;) {
    int fd;
    if (relay) {
      fd = pair_relay_open(tty, deadline, psk_text, ascii);
      if (fd < 0) { result = running && monotime() < deadline ? 3 : 1; break; }
    } else {
      struct pollfd pf = {listener, POLLIN, 0};
      if (poll(&pf, 1, 100) <= 0) continue;
      fd = accept(listener, NULL, NULL);
      if (fd < 0) continue;
    }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    double end = monotime() + 30; if (end > deadline) end = deadline;
    int status = pair_attempt(fd, input, tty, end, port, psk, relay); close(fd); attempts++;
    if (!status) { result = 0; break; }
    if (status == -2) break;
    fprintf(tty, "\n连接中断或握手失败（%d/5）。\n", attempts); fflush(tty);
  }
  if (result) fprintf(tty, "\n配对被拒绝、超时或尝试次数已用尽。\n");
  if (tty != stderr) fclose(tty);
  if (input != STDIN_FILENO) close(input);
  if (listener >= 0) close(listener);
  crypto_wipe(psk, sizeof(psk)); crypto_wipe(psk_text, strlen(psk_text)); free(psk_text);
  return result;
}
#endif
