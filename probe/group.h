#ifndef NP_GROUP_H
#define NP_GROUP_H
#define GROUPS 256
#define GROUP_SLOTS 32
#define MAX_BLOB 7168
typedef char GroupFrameBudget[(GROUP_SLOTS * (MAX_BLOB + 128) + 256 < MAX_FRAME) ? 1 : -1];
typedef char GroupSnapshotBudget[(4 * ((MAX_NODE_JSON + 28 + 2) / 3) < MAX_BLOB) ? 1 : -1];
static const char *relay_addr, *relay_token, *group_secret, *group_upstream;
static uint8_t relay_key[32], enc_key[32], signing_key[64];
static char group_id[65];
typedef struct {
  char slot[33];
  char *blob;
  time_t seen;
} GroupSlot;
typedef struct {
  char gid[65];
  GroupSlot slots[GROUP_SLOTS];
} Group;
static Group groups[GROUPS];
static struct { char gid[65], rid[33]; time_t seen; } group_rids[256];
static unsigned group_rid_pos;
static void hex_encode(char *out, const uint8_t *in, size_t n) {
  for (size_t i = 0; i < n; i++) {
    out[i * 2] = "0123456789abcdef"[in[i] >> 4];
    out[i * 2 + 1] = "0123456789abcdef"[in[i] & 15];
  }
  out[n * 2] = 0;
}
static int hex_decode(uint8_t *out, const char *s, size_t n) {
  if (!s || strlen(s) != n * 2 || strspn(s, "0123456789abcdefABCDEF") != n * 2)
    return -1;
  for (size_t i = 0; i < n; i++) {
    unsigned char a = (unsigned char)tolower((unsigned char)s[i * 2]), b = (unsigned char)tolower((unsigned char)s[i * 2 + 1]);
    out[i] = (uint8_t)((a <= '9' ? a - '0' : a - 'a' + 10) * 16 +
                      (b <= '9' ? b - '0' : b - 'a' + 10));
  }
  return 0;
}
static void group_hash(uint8_t out[32], const char *prefix, const uint8_t *p, size_t n) {
  crypto_sha512_ctx ctx;
  uint8_t hash[64];
  crypto_sha512_init(&ctx);
  crypto_sha512_update(&ctx, (const uint8_t *)prefix, strlen(prefix));
  crypto_sha512_update(&ctx, p, n);
  crypto_sha512_final(&ctx, hash);
  memcpy(out, hash, 32);
  crypto_wipe(hash, sizeof(hash));
}
static void group_init(void) {
  uint8_t seed[32], pub[32];
  group_hash(enc_key, "npulse-e2e-enc:", (const uint8_t *)group_secret, strlen(group_secret));
  group_hash(seed, "npulse-e2e-sign:", (const uint8_t *)group_secret, strlen(group_secret));
  crypto_ed25519_key_pair(signing_key, pub, seed);
  hex_encode(group_id, pub, 32);
}
static void group_slot(char out[33], const char *id) {
  crypto_sha512_ctx ctx;
  uint8_t hash[64];
  crypto_sha512_init(&ctx);
  crypto_sha512_update(&ctx, (const uint8_t *)"npulse-e2e-slot:", 16);
  crypto_sha512_update(&ctx, enc_key, 32);
  crypto_sha512_update(&ctx, (const uint8_t *)id, strlen(id));
  crypto_sha512_final(&ctx, hash);
  hex_encode(out, hash, 16);
  crypto_wipe(hash, sizeof(hash));
}
static char *base64_encode(const uint8_t *p, size_t n) {
  const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  char *s = malloc(4 * ((n + 2) / 3) + 1);
  if (!s) return NULL;
  size_t j = 0;
  for (size_t i = 0; i < n; i += 3) {
    unsigned v = (unsigned)p[i] << 16;
    if (i + 1 < n) v |= (unsigned)p[i + 1] << 8;
    if (i + 2 < n) v |= p[i + 2];
    s[j++] = alphabet[v >> 18];
    s[j++] = alphabet[(v >> 12) & 63];
    s[j++] = i + 1 < n ? alphabet[(v >> 6) & 63] : '=';
    s[j++] = i + 2 < n ? alphabet[v & 63] : '=';
  }
  s[j] = 0;
  return s;
}
static int valid_blob(const char *s) {
  if (!s) return 0;
  size_t n = strlen(s), raw = strspn(s, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
  return n >= 40 && n <= MAX_BLOB && n % 4 == 0 &&
         (raw == n || (raw == n - 1 && s[raw] == '=') ||
          (raw == n - 2 && !strcmp(s + raw, "==")));
}
static void group_expire(time_t now) {
  for (int i = 0; i < GROUPS; i++) {
    int live = 0;
    for (int j = 0; j < GROUP_SLOTS; j++) {
      GroupSlot *s = &groups[i].slots[j];
      if (s->blob && now - s->seen > 600) {
        free(s->blob);
        memset(s, 0, sizeof(*s));
      }
      live |= s->blob != NULL;
    }
    if (!live) groups[i].gid[0] = 0;
  }
}
static int group_replay(const char *gid, const char *rid, time_t now) {
  for (int i = 0; i < 256; i++)
    if (group_rids[i].seen && now - group_rids[i].seen <= 240 &&
        !strcmp(group_rids[i].gid, gid) && !strcmp(group_rids[i].rid, rid)) return -1;
  snprintf(group_rids[group_rid_pos].gid, 65, "%s", gid);
  snprintf(group_rids[group_rid_pos].rid, 33, "%s", rid);
  group_rids[group_rid_pos].seen = now;
  group_rid_pos = (group_rid_pos + 1) % 256;
  return 0;
}
static char *group_request(Json *j, long long stamp, time_t now) {
  char *gid = string(j, field(j, 0, "gid"));
  char *rid = string(j, field(j, 0, "rid"));
  char *sig = string(j, field(j, 0, "sig"));
  char *slot = NULL, *blob = NULL, *response = NULL;
  uint8_t pub[32], signature[64], rid_bytes[16], slot_bytes[16];
  int push = eq(j, field(j, 0, "op"), "gpush");
  if (!push && !eq(j, field(j, 0, "op"), "gget")) goto done;
  if (hex_decode(pub, gid, 32) || hex_decode(signature, sig, 64) || hex_decode(rid_bytes, rid, 16)) goto done;
  Buffer message = buffer();
  if (push) {
    slot = string(j, field(j, 0, "slot"));
    blob = string(j, field(j, 0, "blob"));
    if (hex_decode(slot_bytes, slot, 16) || !valid_blob(blob)) {
      free(message.s);
      goto done;
    }
    add(&message, "npulse-gpush\n%s\n%s\n%lld\n%s\n%s", gid, slot, stamp, rid, blob);
  } else add(&message, "npulse-gget\n%s\n%lld\n%s", gid, stamp, rid);
  int bad = crypto_ed25519_check(signature, pub, (const uint8_t *)message.s, message.n);
  free(message.s);
  if (bad) goto done;
  if (group_replay(gid, rid, now)) goto done;
  group_expire(now);
  Group *g = NULL, *empty = NULL;
  for (int i = 0; i < GROUPS; i++) {
    if (!groups[i].gid[0] && !empty) empty = &groups[i];
    if (!strcmp(groups[i].gid, gid)) g = &groups[i];
  }
  if (push) {
    if (!g) g = empty;
    if (!g) goto done;
    GroupSlot *entry = NULL;
    for (int i = 0; i < GROUP_SLOTS; i++)
      if (g->slots[i].blob && !strcmp(g->slots[i].slot, slot)) entry = &g->slots[i];
    if (!entry)
      for (int i = 0; i < GROUP_SLOTS; i++)
        if (!g->slots[i].blob) { entry = &g->slots[i]; break; }
    if (!entry) goto done;
    free(entry->blob);
    entry->blob = blob;
    blob = NULL;
    entry->seen = now;
    snprintf(entry->slot, sizeof(entry->slot), "%s", slot);
    snprintf(g->gid, sizeof(g->gid), "%s", gid);
  }
  Buffer b = buffer();
  add(&b, "{\"ok\":true,\"rid\":\"%s\"", rid);
  if (!push) {
    add(&b, ",\"blobs\":[");
    int comma = 0;
    if (g) for (int i = 0; i < GROUP_SLOTS; i++) {
      GroupSlot *s = &g->slots[i];
      if (s->blob) add(&b, "%s{\"slot\":\"%s\",\"blob\":\"%s\",\"age\":%lld}",
                       comma++ ? "," : "", s->slot, s->blob, (long long)(now - s->seen));
    }
    add(&b, "]");
  }
  add(&b, "}");
  response = b.s;
done:
  free(gid); free(rid); free(sig); free(slot); free(blob);
  return response;
}
static char *group_push_json(const char *snapshot_json) {
  Json j;
  if (parse(&j, snapshot_json)) return NULL;
  char *id = string(&j, field(&j, 0, "id"));
  if (!id) return NULL;
  char slot[33], rid[33], sig[129];
  uint8_t random[16], signature[64];
  group_slot(slot, id);
  free(id);
  size_t n = strlen(snapshot_json);
  uint8_t *sealed = malloc(n + 28);
  if (!sealed) return NULL;
  if (random_bytes(sealed, 12) || random_bytes(random, 16)) { free(sealed); return NULL; }
  hex_encode(rid, random, 16);
  Buffer ad = buffer();
  add(&ad, "%s:%s", group_id, slot);
  crypto_aead_ctx ctx;
  crypto_aead_init_ietf(&ctx, enc_key, sealed);
  crypto_aead_write(&ctx, sealed + 12, sealed + 12 + n, (const uint8_t *)ad.s, ad.n, (const uint8_t *)snapshot_json, n);
  crypto_wipe(&ctx, sizeof(ctx));
  free(ad.s);
  char *blob = base64_encode(sealed, n + 28);
  free(sealed);
  if (!valid_blob(blob)) { free(blob); return NULL; }
  long long stamp = (long long)time(NULL);
  Buffer message = buffer();
  add(&message, "npulse-gpush\n%s\n%s\n%lld\n%s\n%s", group_id, slot, stamp, rid, blob);
  crypto_ed25519_sign(signature, signing_key, (const uint8_t *)message.s, message.n);
  free(message.s);
  hex_encode(sig, signature, 64);
  Buffer b = buffer();
  add(&b, "{\"op\":\"gpush\",\"ts\":%lld,\"rid\":\"%s\",\"gid\":\"%s\",\"slot\":\"%s\",\"blob\":\"%s\",\"sig\":\"%s\"}", stamp, rid, group_id, slot, blob, sig);
  free(blob);
  return b.s;
}
#endif
