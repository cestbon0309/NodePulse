#ifndef NP_ADMIN_H
#define NP_ADMIN_H
#include <limits.h>
#include <pwd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#ifdef __linux__
#include <sys/reboot.h>
#endif
#define ADMIN_FRAME (128 * 1024)
#define ADMIN_HIGH_WATER (256 * 1024)
#define ADMIN_CHILDREN 128
static const char *admin_keys_text;
static uint8_t admin_keys[32][32];
static int admin_key_count;
static struct { uint8_t rid[16]; time_t seen; } admin_rids[256];
typedef struct {
  pid_t pid, foreground;
  int exited, code, orphan;
  double kill_at;
} AdminChild;
static AdminChild admin_children[ADMIN_CHILDREN];
static struct { int action; double at; pid_t helper; } admin_power;
typedef struct {
  int fd, dir, overwrite;
  uint64_t size, written;
  mode_t mode;
  int handle;
  char *path, *name, *part;
} AdminPut;
typedef struct {
  int fd, id, child;
  uint8_t *input;
  size_t len, sent;
} AdminPTY;
struct Admin {
  uint8_t rx[32], tx[32];
  uint64_t rx_seq, tx_seq, queued, sent_total, power_mark;
  uint8_t *in, *out;
  size_t have, want, outlen, sent;
  double active;
  char who[65];
  int next_handle, next_pty, power_pending;
  AdminPut puts[4];
  AdminPTY ptys[4];
};
static void admin_sigchld(int sig) { (void)sig; }
static int admin_init(void) {
  if (!admin_keys_text) return 0;
  if ((!listen_addr && !group_upstream) || !*admin_keys_text) return -1;
  const char *p = admin_keys_text;
  do {
    size_t n = strcspn(p, ",");
    char hex[65];
    if (n != 64 || admin_key_count == 32) return -1;
    memcpy(hex, p, n); hex[n] = 0;
    if (hex_decode(admin_keys[admin_key_count++], hex, 32)) return -1;
    p += n;
    if (!*p) return 0;
  } while (*++p);
  return -1;
}
static int admin_number(Json *j, const char *name, long long *out) {
  int t = field(j, 0, name);
  if (t < 0 || (j->t[t].type != '-' && !isdigit(j->t[t].type))) return -1;
  char *end;
  errno = 0;
  *out = strtoll(j->s + j->t[t].start, &end, 10);
  return errno || end != j->s + j->t[t].end ? -1 : 0;
}
static int admin_bool(Json *j, const char *name, int *out) {
  int t = field(j, 0, name);
  if (t < 0) return -1;
  size_t n = (size_t)(j->t[t].end - j->t[t].start);
  const char *s = j->s + j->t[t].start;
  if (n == 4 && !memcmp(s, "true", 4)) { *out = 1; return 0; }
  if (n == 5 && !memcmp(s, "false", 5)) { *out = 0; return 0; }
  return -1;
}
static void admin_log(Admin *a, const char *op, const char *path, const char *to) {
  Buffer b = buffer();
  add(&b, "admin who=%.16s op=", a->who); quote(&b, op);
  if (path) { add(&b, " path="); quote(&b, path); }
  if (to) { add(&b, " to="); quote(&b, to); }
  fprintf(stderr, "%s\n", b.s);
  free(b.s);
}
static void admin_nonce(uint8_t nonce[12], uint64_t seq) {
  memset(nonce, 0, 12);
  for (int i = 0; i < 8; i++) nonce[i] = (uint8_t)(seq >> (8 * i));
}
static int admin_queue(Admin *a, const char *json) {
  size_t n = strlen(json), pending = a->outlen - a->sent;
  if (!n || n > ADMIN_FRAME || a->tx_seq == UINT64_MAX || pending > 2 * ADMIN_HIGH_WATER) return -1;
  if (a->sent) memmove(a->out, a->out + a->sent, pending);
  a->sent = 0; a->outlen = pending;
  uint8_t *p = realloc(a->out, pending + n + 20);
  if (!p) return -1;
  a->out = p; p += pending;
  uint32_t be = htonl((uint32_t)n);
  memcpy(p, &be, 4);
  uint8_t nonce[12]; admin_nonce(nonce, a->tx_seq++);
  crypto_aead_ctx ctx;
  crypto_aead_init_ietf(&ctx, a->tx, nonce);
  crypto_aead_write(&ctx, p + 4, p + 4 + n, p, 4, (const uint8_t *)json, n);
  crypto_wipe(&ctx, sizeof(ctx));
  a->outlen += n + 20; a->queued += n + 20;
  return 0;
}
static int admin_emit(Admin *a, Buffer *b) {
  add(b, "}");
  int result = admin_queue(a, b->s);
  free(b->s);
  return result;
}
static uint8_t *admin_unbase64(const char *s, size_t *size, size_t max) {
  const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  if (!s) return NULL;
  size_t n = strlen(s), used = 0;
  if (n % 4 || n > 4 * ((max + 2) / 3)) return NULL;
  uint8_t *out = malloc(n / 4 * 3 + 1);
  if (!out) return NULL;
  for (size_t i = 0; i < n; i += 4) {
    unsigned v = 0; int padding = 0;
    for (int k = 0; k < 4; k++) {
      const char *p = s[i + k] == '=' ? NULL : strchr(alphabet, s[i + k]);
      if (p && !padding) v = v * 64 + (unsigned)(p - alphabet);
      else if (s[i + k] == '=' && k >= 2 && i + 4 == n) { padding++; v *= 64; }
      else goto bad;
    }
    if (padding > 2 || (padding == 2 && (v & 0xffff)) || (padding == 1 && (v & 0xff))) goto bad;
    out[used++] = (uint8_t)(v >> 16);
    if (padding < 2) out[used++] = (uint8_t)(v >> 8);
    if (!padding) out[used++] = (uint8_t)v;
  }
  if (used > max) goto bad;
  *size = used;
  return out;
bad:
  free(out); return NULL;
}
static char *admin_hello(Json *j, long long stamp, time_t now, Admin **session, const char *identity_secret) {
  char *node = string(j, field(j, 0, "node")), *rid = string(j, field(j, 0, "rid"));
  char *epk = string(j, field(j, 0, "epk")), *apk = string(j, field(j, 0, "apk"));
  char *sig = string(j, field(j, 0, "sig")), *result = NULL;
  uint8_t pub[32], eph[32], signature[64], rid_bytes[16], sk[32] = {0}, shared[32] = {0}, k[64] = {0};
  long long version;
  if (!admin_key_count || !eq(j, field(j, 0, "op"), "admin") || stamp < (long long)now - 120 || stamp > (long long)now + 120 ||
      admin_number(j, "v", &version) || version != 1 || !node || strcmp(node, node_id) ||
      hex_decode(pub, apk, 32) || hex_decode(eph, epk, 32) || hex_decode(signature, sig, 64) || hex_decode(rid_bytes, rid, 16)) goto done;
  int allowed = 0, vacant = -1;
  for (int i = 0; i < admin_key_count; i++) allowed |= crypto_verify32(pub, admin_keys[i]) == 0;
  if (!allowed) goto done;
  for (int i = 0; i < 256; i++) {
    if (!admin_rids[i].seen || now - admin_rids[i].seen > 240) vacant = i;
    else if (!memcmp(admin_rids[i].rid, rid_bytes, 16)) goto done;
  }
  if (vacant < 0) goto done;
  Buffer message = buffer();
  add(&message, "npulse-admin-hello\n%s\n%lld\n%s\n%s", node, stamp, rid, epk);
  int bad = crypto_ed25519_check(signature, pub, (const uint8_t *)message.s, message.n);
  free(message.s);
  if (bad || random_bytes(sk, 32)) goto done;
  uint8_t probe_pub[32], zero[32] = {0};
  crypto_x25519_public_key(probe_pub, sk);
  crypto_x25519(shared, sk, eph);
  if (!crypto_verify32(shared, zero)) goto done;
  crypto_sha512_ctx hash;
  crypto_sha512_init(&hash);
  crypto_sha512_update(&hash, (const uint8_t *)"npulse-admin-sess", 17);
  crypto_sha512_update(&hash, shared, 32);
  crypto_sha512_update(&hash, eph, 32);
  crypto_sha512_update(&hash, probe_pub, 32);
  crypto_sha512_final(&hash, k);
  Admin *a = calloc(1, sizeof(*a));
  if (!a) goto done;
  for (int i = 0; i < 4; i++) { a->puts[i].fd = a->puts[i].dir = -1; a->ptys[i].fd = -1; }
  a->in = malloc(5);
  if (!a->in) { free(a); goto done; }
  a->want = 4; a->active = monotime();
  a->next_handle = a->next_pty = 1;
  memcpy(a->rx, k, 32); memcpy(a->tx, k + 32, 32);
  snprintf(a->who, sizeof(a->who), "%s", apk);
  char epk_p[65], mac_hex[65]; uint8_t id_key[32], mac[64];
  hex_encode(epk_p, probe_pub, 32);
  group_hash(id_key, "npulse-admin-id:", (const uint8_t *)identity_secret, strlen(identity_secret));
  message = buffer();
  add(&message, "npulse-admin-ack\n%s\n%s\n%s", rid, epk, epk_p);
  crypto_sha512_hmac(mac, id_key, 32, (const uint8_t *)message.s, message.n);
  hex_encode(mac_hex, mac, 32);
  free(message.s); crypto_wipe(id_key, 32); crypto_wipe(mac, 64);
  Buffer ack = buffer();
  add(&ack, "{\"ok\":true,\"rid\":\"%s\",\"epk\":\"%s\",\"mac\":\"%s\"}", rid, epk_p, mac_hex);
  result = ack.s; *session = a;
  memcpy(admin_rids[vacant].rid, rid_bytes, 16); admin_rids[vacant].seen = now;
  admin_log(a, "hello", NULL, NULL);
done:
  free(node); free(rid); free(epk); free(apk); free(sig);
  crypto_wipe(sk, sizeof(sk)); crypto_wipe(shared, sizeof(shared)); crypto_wipe(k, sizeof(k));
  return result;
}
static int admin_parent(const char *path, char **name) {
  size_t n = strlen(path);
  if (!n || n >= PATH_MAX) { errno = EINVAL; return -1; }
  char *copy = strdup(path);
  if (!copy) return -1;
  while (n > 1 && copy[n - 1] == '/') copy[--n] = 0;
  char *slash = strrchr(copy, '/'), *base = slash ? slash + 1 : copy;
  if (!*base || !strcmp(base, ".") || !strcmp(base, "..")) { free(copy); errno = EINVAL; return -1; }
  *name = strdup(base);
  if (!*name) { free(copy); return -1; }
  const char *dir = ".";
  if (slash) { if (slash == copy) dir = "/"; else { *slash = 0; dir = copy; } }
  int fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  int err = errno; free(copy); errno = err;
  return fd;
}
static void admin_put_clear(AdminPut *p, int aborting) {
  if (p->fd >= 0) close(p->fd);
  if (p->dir >= 0) {
    if (aborting && p->part) unlinkat(p->dir, p->part, 0);
    close(p->dir);
  }
  free(p->path); free(p->name); free(p->part);
  memset(p, 0, sizeof(*p)); p->fd = p->dir = -1;
}
static int admin_remove(int parent, const char *name, int recursive, int depth) {
  struct stat st;
  if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW)) return -1;
  if (!S_ISDIR(st.st_mode)) return unlinkat(parent, name, 0);
  if (recursive) {
    if (depth > 64) { errno = ELOOP; return -1; }
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    DIR *dir = fdopendir(fd);
    if (!dir) { int err = errno; close(fd); errno = err; return -1; }
    struct dirent *e;
    for (;;) {
      errno = 0; e = readdir(dir);
      if (!e) { int err = errno; closedir(dir); if (err) { errno = err; return -1; } break; }
      if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
      if (admin_remove(fd, e->d_name, 1, depth + 1)) { int err = errno; closedir(dir); errno = err; return -1; }
    }
  }
  return unlinkat(parent, name, AT_REMOVEDIR);
}
static int admin_stat(Buffer *b, int dir, const char *name, const struct stat *st) {
  char type = S_ISREG(st->st_mode) ? 'f' : S_ISDIR(st->st_mode) ? 'd' : S_ISLNK(st->st_mode) ? 'l' : 'o';
  add(b, "\"type\":\"%c\",\"size\":%lld,\"mode\":%u,\"mtime\":%lld", type, (long long)st->st_size, (unsigned)(st->st_mode & 07777), (long long)st->st_mtime);
  if (type == 'l') {
    char target[PATH_MAX + 1];
    ssize_t n = readlinkat(dir, name, target, PATH_MAX);
    if (n < 0) return -1;
    target[n] = 0; add(b, ",\"target\":"); quote(b, target);
  }
  return 0;
}
static void admin_child_signal(AdminChild *c, int sig) {
  kill(-c->pid, sig);
  if (c->foreground > 0 && c->foreground != c->pid) kill(-c->foreground, sig);
  if (!c->exited) kill(c->pid, sig);
}
static void admin_retire(AdminPTY *p) {
  if (p->id && p->fd >= 0) {
    pid_t foreground = tcgetpgrp(p->fd);
    if (foreground > 0) admin_children[p->child].foreground = foreground;
  }
  if (p->fd >= 0) close(p->fd);
  free(p->input);
  if (p->id) {
    AdminChild *child = &admin_children[p->child];
    admin_child_signal(child, SIGHUP); child->orphan = 1;
    if (!child->kill_at) child->kill_at = monotime() + 2;
  }
  memset(p, 0, sizeof(*p)); p->fd = -1;
}
static void admin_free(Admin *a) {
  for (int i = 0; i < 4; i++) { admin_put_clear(&a->puts[i], 1); admin_retire(&a->ptys[i]); }
  if (a->power_pending) admin_power.action = 0;
  free(a->in); free(a->out); crypto_wipe(a, sizeof(*a)); free(a);
}
static const char *admin_shell(struct passwd *pw) {
  if (pw && pw->pw_shell && *pw->pw_shell && !access(pw->pw_shell, X_OK)) return pw->pw_shell;
  return !access("/bin/ash", X_OK) ? "/bin/ash" : "/bin/sh";
}
static int admin_request(Admin *a, char *plain) {
  Json j;
  if (parse(&j, plain) || j.t[0].type != '{') return -1;
  char *t = string(&j, field(&j, 0, "t")), *path = string(&j, field(&j, 0, "path"));
  char *to = string(&j, field(&j, 0, "to")), *from = string(&j, field(&j, 0, "from"));
  long long id = 0, value = 0;
  int input = t && !strcmp(t, "pty_in"), error = 0;
  if (!t || (admin_number(&j, "id", &id) && !input)) { free(t); free(path); free(to); free(from); return -1; }
  const char *logpath = path ? path : from;
  if (!logpath && !admin_number(&j, "handle", &value)) {
    for (int i = 0; i < 4; i++) if (a->puts[i].handle && a->puts[i].handle == value) logpath = a->puts[i].path;
  }
  admin_log(a, t, logpath, to);
  Buffer b = buffer(); add(&b, "{\"id\":%lld,\"ok\":true", id);
  if (path && (!*path || strlen(path) >= PATH_MAX)) { error = EINVAL; goto done; }
  if (!strcmp(t, "ping")) { }
  else if (!strcmp(t, "info")) {
    struct passwd *pw = getpwuid(getuid());
    add(&b, ",\"hostname\":"); quote(&b, hostname_buf);
    add(&b, ",\"uid\":%lu,\"shell\":", (unsigned long)getuid()); quote(&b, admin_shell(pw));
    add(&b, ",\"home\":"); quote(&b, pw && pw->pw_dir ? pw->pw_dir : "/");
    add(&b, ",\"admin_version\":1");
#ifdef NPULSE_ADMIN_TEST
    const char *record = getenv("NPULSE_TEST_POWER_FILE");
    if (record && *record) add(&b, ",\"power_test_hook\":true");
#endif
  } else if (!strcmp(t, "ls") && path) {
    DIR *dir = opendir(path);
    if (!dir) { error = errno; goto done; }
    add(&b, ",\"entries\":[");
    int count = 0, truncated = 0;
    for (;;) {
      errno = 0; struct dirent *e = readdir(dir);
      if (!e) { error = errno; break; }
      if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
      if (count == 5000) { truncated = 1; break; }
      struct stat st;
      if (fstatat(dirfd(dir), e->d_name, &st, AT_SYMLINK_NOFOLLOW)) { error = errno; break; }
      Buffer entry = buffer(); add(&entry, "{\"name\":"); quote(&entry, e->d_name); add(&entry, ",");
      if (admin_stat(&entry, dirfd(dir), e->d_name, &st)) { error = errno; free(entry.s); break; }
      add(&entry, "}");
      if (b.n + entry.n + 64 > ADMIN_FRAME) { truncated = 1; free(entry.s); break; }
      add(&b, "%s%s", count++ ? "," : "", entry.s); free(entry.s);
    }
    closedir(dir); add(&b, "],\"truncated\":%s", truncated ? "true" : "false");
  } else if (!strcmp(t, "stat") && path) {
    struct stat st;
    if (lstat(path, &st)) { error = errno; goto done; }
    add(&b, ","); if (admin_stat(&b, AT_FDCWD, path, &st)) error = errno;
  } else if (!strcmp(t, "get") && path) {
    long long length, offset;
    if (admin_number(&j, "offset", &offset) || offset < 0 || admin_number(&j, "len", &length) || length < 0 || length > 65536) { error = EINVAL; goto done; }
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { error = errno; goto done; }
    struct stat st; uint8_t data[65536]; ssize_t n = -1;
    if (fstat(fd, &st)) error = errno;
    else if (!S_ISREG(st.st_mode)) error = EINVAL;
    else { do { n = pread(fd, data, (size_t)length, (off_t)offset); } while (n < 0 && errno == EINTR); if (n < 0) error = errno; }
    close(fd);
    if (error) goto done;
    char *encoded = base64_encode(data, (size_t)n);
    if (!encoded) { error = ENOMEM; goto done; }
    add(&b, ",\"data\":\"%s\",\"size\":%lld,\"eof\":%s", encoded, (long long)st.st_size, (uint64_t)offset + (size_t)n >= (uint64_t)st.st_size ? "true" : "false"); free(encoded);
  } else if (!strcmp(t, "put_begin") && path) {
    long long size, mode = 0600; int overwrite;
    if (admin_number(&j, "size", &size) || size < 0 || admin_bool(&j, "overwrite", &overwrite) ||
        (field(&j, 0, "mode") >= 0 && (admin_number(&j, "mode", &mode) || mode < 0 || mode > 07777))) { error = EINVAL; goto done; }
    AdminPut *p = NULL;
    for (int i = 0; i < 4; i++) if (!a->puts[i].handle) { p = &a->puts[i]; break; }
    if (!p || a->next_handle == INT_MAX) { error = EMFILE; goto done; }
    p->dir = admin_parent(path, &p->name);
    if (p->dir < 0) { error = errno; admin_put_clear(p, 0); goto done; }
    struct stat st;
    if (!overwrite && !fstatat(p->dir, p->name, &st, AT_SYMLINK_NOFOLLOW)) { error = EEXIST; admin_put_clear(p, 0); goto done; }
    size_t n = strlen(p->name) + sizeof(".npulse-part");
    p->part = malloc(n); p->path = strdup(path);
    if (!p->part || !p->path) { error = ENOMEM; admin_put_clear(p, 0); goto done; }
    snprintf(p->part, n, "%s.npulse-part", p->name);
    p->fd = openat(p->dir, p->part, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (p->fd < 0) { error = errno; admin_put_clear(p, 0); goto done; }
    p->handle = a->next_handle++; p->size = (uint64_t)size; p->mode = (mode_t)mode; p->overwrite = overwrite;
    add(&b, ",\"handle\":%d", p->handle);
  } else if (!strcmp(t, "put") || !strcmp(t, "put_end") || !strcmp(t, "put_abort")) {
    if (admin_number(&j, "handle", &value)) { error = EINVAL; goto done; }
    AdminPut *p = NULL;
    for (int i = 0; i < 4; i++) if (a->puts[i].handle && a->puts[i].handle == value) p = &a->puts[i];
    if (!p) { error = EBADF; goto done; }
    if (!strcmp(t, "put_abort")) {
      if (unlinkat(p->dir, p->part, 0) && errno != ENOENT) { error = errno; goto done; }
      admin_put_clear(p, 0);
    }
    else if (!strcmp(t, "put_end")) {
      if (p->written != p->size) { error = EINVAL; goto done; }
      if (fchmod(p->fd, p->mode) || fsync(p->fd)) { error = errno; goto done; }
      int r = p->overwrite ? renameat(p->dir, p->part, p->dir, p->name) : linkat(p->dir, p->part, p->dir, p->name, 0);
      if (r) { error = errno; goto done; }
      if (!p->overwrite && unlinkat(p->dir, p->part, 0)) { error = errno; goto done; }
      admin_put_clear(p, 0);
    } else {
      long long offset; size_t size = 0;
      char *encoded = string(&j, field(&j, 0, "data"));
      uint8_t *data = admin_unbase64(encoded, &size, 65536); free(encoded);
      if (!data || admin_number(&j, "offset", &offset) || offset < 0 || (uint64_t)offset != p->written || size > p->size - p->written) { free(data); error = EINVAL; goto done; }
      size_t off = 0;
      while (off < size) {
        ssize_t n = write(p->fd, data + off, size - off);
        if (n > 0) { off += (size_t)n; p->written += (size_t)n; }
        else if (n < 0 && errno == EINTR) continue;
        else { error = n < 0 ? errno : EIO; break; }
      }
      crypto_wipe(data, size); free(data);
      if (error) admin_put_clear(p, 1);
    }
  } else if (!strcmp(t, "rm") && path) {
    int recursive;
    if (admin_bool(&j, "recursive", &recursive)) { error = EINVAL; goto done; }
    char *name = NULL; int fd = admin_parent(path, &name);
    if (fd < 0) error = errno;
    else { if (admin_remove(fd, name, recursive, 0)) error = errno; close(fd); }
    free(name);
  } else if (!strcmp(t, "mkdir") && path) { if (mkdir(path, 0755)) error = errno;
  } else if (!strcmp(t, "mv") && from && to) {
    int overwrite = 0; struct stat st;
    if (field(&j, 0, "overwrite") >= 0 && admin_bool(&j, "overwrite", &overwrite)) error = EINVAL;
    else if (!overwrite && !lstat(to, &st)) error = EEXIST;
    else if (!overwrite && errno != ENOENT) error = errno;
    else if (rename(from, to)) error = errno;
  } else if (!strcmp(t, "pty_open")) {
    long long cols, rows;
    if (admin_number(&j, "cols", &cols) || admin_number(&j, "rows", &rows) || cols < 1 || cols > 65535 || rows < 1 || rows > 65535) { error = EINVAL; goto done; }
    AdminPTY *p = NULL; int child = -1;
    for (int i = 0; i < 4; i++) if (!a->ptys[i].id) { p = &a->ptys[i]; break; }
    for (int i = 0; i < ADMIN_CHILDREN; i++) if (!admin_children[i].pid) { child = i; break; }
    if (!p || child < 0 || a->next_pty == INT_MAX) { error = EMFILE; goto done; }
    struct passwd *pw = getpwuid(getuid());
    const char *shell = admin_shell(pw), *home = pw && pw->pw_dir ? pw->pw_dir : "/";
    struct winsize ws = {(unsigned short)rows, (unsigned short)cols, 0, 0};
    pid_t pid = forkpty(&p->fd, NULL, NULL, &ws);
    if (pid < 0) { error = errno; p->fd = -1; goto done; }
    if (!pid) {
      setsid(); signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGPIPE, SIG_DFL); signal(SIGCHLD, SIG_DFL);
      setenv("TERM", "xterm-256color", 1); setenv("HOME", home, 1); setenv("SHELL", shell, 1);
      if (chdir(home) && chdir("/")) _exit(127);
      execl(shell, shell, "-l", (char *)NULL); _exit(127);
    }
    admin_children[child] = (AdminChild){.pid = pid};
    p->child = child; p->id = a->next_pty++;
    fcntl(p->fd, F_SETFL, O_NONBLOCK); fcntl(p->fd, F_SETFD, FD_CLOEXEC);
    add(&b, ",\"pty\":%d", p->id);
  } else if (!strcmp(t, "pty_in") || !strcmp(t, "pty_resize") || !strcmp(t, "pty_close")) {
    if (admin_number(&j, "pty", &value)) { error = EINVAL; goto done; }
    AdminPTY *p = NULL;
    for (int i = 0; i < 4; i++) if (a->ptys[i].id && a->ptys[i].id == value) p = &a->ptys[i];
    if (!p) { error = EBADF; goto done; }
    if (input) {
      size_t n = 0; char *encoded = string(&j, field(&j, 0, "data"));
      uint8_t *data = admin_unbase64(encoded, &n, 65536); free(encoded);
      size_t pending = p->len - p->sent;
      if (!data || p->fd < 0 || pending + n > ADMIN_FRAME) { free(data); error = EINVAL; goto done; }
      if (p->sent) memmove(p->input, p->input + p->sent, pending);
      p->sent = 0; p->len = pending;
      uint8_t *buf = realloc(p->input, pending + n + 1);
      if (!buf) { free(data); error = ENOMEM; goto done; }
      p->input = buf; memcpy(buf + pending, data, n); p->len += n;
      crypto_wipe(data, n); free(data);
    } else if (!strcmp(t, "pty_resize")) {
      long long cols, rows;
      if (admin_number(&j, "cols", &cols) || admin_number(&j, "rows", &rows) || cols < 1 || cols > 65535 || rows < 1 || rows > 65535) { error = EINVAL; goto done; }
      struct winsize ws = {(unsigned short)rows, (unsigned short)cols, 0, 0};
      if (ioctl(p->fd, TIOCSWINSZ, &ws)) error = errno;
    } else {
      AdminChild *c = &admin_children[p->child];
      pid_t foreground = tcgetpgrp(p->fd); if (foreground > 0) c->foreground = foreground;
      admin_child_signal(c, SIGHUP); if (!c->kill_at) c->kill_at = monotime() + 2;
    }
  } else if (!strcmp(t, "power")) {
    char *action = string(&j, field(&j, 0, "action"));
    int rebooting = action && !strcmp(action, "reboot"), off = action && !strcmp(action, "poweroff");
    if (!rebooting && !off) error = EINVAL;
    else if (admin_power.action || admin_power.helper > 0) error = EBUSY;
    else {
      int test = 0;
#ifdef NPULSE_ADMIN_TEST
      const char *record = getenv("NPULSE_TEST_POWER_FILE"); test = record && *record;
#endif
      if (!test && geteuid() != 0) error = EPERM;
#ifndef __linux__
      else if (!test) error = ENOTSUP;
#endif
      else { admin_log(a, "power", action, NULL); admin_power.action = rebooting ? 1 : 2; a->power_pending = 1; }
    }
    free(action);
  } else error = EINVAL;
done:
  free(t); free(path); free(to); free(from);
  if (input) { free(b.s); return 0; }
  if (error) { free(b.s); b = buffer(); add(&b, "{\"id\":%lld,\"ok\":false,\"err\":", id); quote(&b, strerror(error)); }
  int result = admin_emit(a, &b);
  if (!result && a->power_pending && !a->power_mark) a->power_mark = a->queued;
  return result;
}
static short admin_events(Admin *a) {
  size_t pending = a->outlen - a->sent;
  return (short)((pending <= ADMIN_HIGH_WATER ? POLLIN : 0) | (pending ? POLLOUT : 0));
}
static void admin_poll(Admin *a, struct pollfd *pf) {
  for (int i = 0; i < 4; i++) {
    AdminPTY *p = &a->ptys[i];
    pf[i] = (struct pollfd){a->outlen - a->sent <= ADMIN_HIGH_WATER ? p->fd : -1, (short)(POLLIN | (p->len > p->sent ? POLLOUT : 0)), 0};
  }
}
static void admin_tick(double now) {
  for (int i = 0; i < ADMIN_CHILDREN; i++) {
    AdminChild *c = &admin_children[i];
    if (!c->pid) continue;
    if (c->kill_at && now >= c->kill_at) { admin_child_signal(c, SIGKILL); c->kill_at = 0; }
    if (!c->exited) {
      int status; pid_t pid = waitpid(c->pid, &status, WNOHANG);
      if (pid == c->pid) { c->exited = 1; c->code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status); }
    }
    if (c->orphan && c->exited && kill(-c->pid, 0) < 0 && errno == ESRCH &&
        (c->foreground <= 0 || (kill(-c->foreground, 0) < 0 && errno == ESRCH))) memset(c, 0, sizeof(*c));
  }
  if (admin_power.helper > 0 && waitpid(admin_power.helper, NULL, WNOHANG) == admin_power.helper) admin_power.helper = 0;
  if (!admin_power.at || now < admin_power.at) return;
  int action = admin_power.action;
  admin_power.at = 0; admin_power.action = 0;
#ifdef NPULSE_ADMIN_TEST
  const char *record = getenv("NPULSE_TEST_POWER_FILE");
  if (record && *record) {
    int fd = open(record, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0) { const char *name = action == 1 ? "reboot\n" : "poweroff\n"; if (write(fd, name, strlen(name)) < 0) perror("admin power record"); close(fd); }
    else perror("admin power record");
    return;
  }
#endif
#ifdef __linux__
  sync();
  if (reboot(action == 1 ? RB_AUTOBOOT : RB_POWER_OFF) < 0) {
    int err = errno; perror("admin reboot");
    if (err == EPERM) {
      admin_power.helper = fork();
      if (!admin_power.helper) { const char *cmd = action == 1 ? "/sbin/reboot" : "/sbin/poweroff"; execl(cmd, cmd, (char *)NULL); _exit(127); }
    }
  }
#else
  (void)action;
#endif
}
static int admin_io(Admin *a, int fd, short events, struct pollfd *pty_pf) {
  if (monotime() - a->active > 600 || (events & (POLLERR | POLLNVAL | POLLHUP))) return -1;
  if ((events & POLLOUT) && a->outlen > a->sent) {
    ssize_t n = send(fd, a->out + a->sent, a->outlen - a->sent, 0);
    if (n > 0) {
      a->sent += (size_t)n; a->sent_total += (size_t)n; a->active = monotime();
      if (a->power_pending && a->sent_total >= a->power_mark) { admin_power.at = monotime() + 1; a->power_pending = 0; }
      if (a->sent == a->outlen) { free(a->out); a->out = NULL; a->sent = a->outlen = 0; }
    } else if (!n || (errno != EAGAIN && errno != EINTR)) return -1;
  }
  if ((events & POLLIN) && a->outlen - a->sent <= ADMIN_HIGH_WATER) {
    ssize_t n = recv(fd, a->in + a->have, a->want - a->have, 0);
    if (n <= 0) { if (!n || (errno != EAGAIN && errno != EINTR)) return -1; }
    else {
      a->have += (size_t)n; a->active = monotime();
      if (a->have == 4 && a->want == 4) {
        uint32_t be; memcpy(&be, a->in, 4); size_t len = ntohl(be);
        if (!len || len > ADMIN_FRAME) return -1;
        uint8_t *p = realloc(a->in, len + 21);
        if (!p) return -1;
        a->in = p; a->want = len + 20;
      } else if (a->have == a->want) {
        size_t len = a->want - 20;
        uint8_t nonce[12]; admin_nonce(nonce, a->rx_seq);
        crypto_aead_ctx ctx; crypto_aead_init_ietf(&ctx, a->rx, nonce);
        int bad = crypto_aead_read(&ctx, a->in + 4, a->in + 4 + len, a->in, 4, a->in + 4, len);
        crypto_wipe(&ctx, sizeof(ctx));
        if (bad || a->rx_seq == UINT64_MAX || memchr(a->in + 4, 0, len)) return -1;
        a->rx_seq++; a->in[4 + len] = 0;
        if (admin_request(a, (char *)a->in + 4)) return -1;
        a->have = 0; a->want = 4;
      }
    }
  }
  for (int i = 0; i < 4; i++) {
    AdminPTY *p = &a->ptys[i];
    if (!p->id) continue;
    AdminChild *child = &admin_children[p->child];
    if (p->fd >= 0) { pid_t foreground = tcgetpgrp(p->fd); if (foreground > 0) admin_children[p->child].foreground = foreground; }
    if (p->fd >= 0 && (pty_pf[i].revents & POLLOUT) && p->len > p->sent) {
      ssize_t n = write(p->fd, p->input + p->sent, p->len - p->sent);
      if (n > 0) { p->sent += (size_t)n; if (p->sent == p->len) { free(p->input); p->input = NULL; p->sent = p->len = 0; } }
      else if (n < 0 && errno != EAGAIN && errno != EINTR) { free(p->input); p->input = NULL; p->len = p->sent = 0; }
    }
    if (p->fd >= 0 && ((pty_pf[i].revents & (POLLIN | POLLHUP)) || child->exited) && a->outlen - a->sent <= ADMIN_HIGH_WATER) {
      uint8_t data[16384]; size_t have = 0;
      while (have < sizeof(data)) {
        ssize_t n = read(p->fd, data + have, sizeof(data) - have);
        if (n > 0) have += (size_t)n;
        else { if (!n || (errno != EAGAIN && errno != EINTR) || (child->exited && errno == EAGAIN)) { close(p->fd); p->fd = -1; } break; }
      }
      if (have) {
        char *encoded = base64_encode(data, have);
        if (!encoded) return -1;
        Buffer b = buffer(); add(&b, "{\"t\":\"pty_out\",\"pty\":%d,\"data\":\"%s\"", p->id, encoded); free(encoded);
        if (admin_emit(a, &b)) return -1;
      }
    }
    if (p->fd < 0 && child->exited) {
      Buffer b = buffer(); add(&b, "{\"t\":\"pty_exit\",\"pty\":%d,\"code\":%d", p->id, child->code);
      if (admin_emit(a, &b)) return -1;
      admin_retire(p);
    }
  }
  return 0;
}
static void admin_shutdown(void) {
  for (int i = 0; i < ADMIN_CHILDREN; i++) if (admin_children[i].pid) {
    admin_child_signal(&admin_children[i], SIGKILL);
    if (!admin_children[i].exited) waitpid(admin_children[i].pid, NULL, WNOHANG);
  }
}
#endif
