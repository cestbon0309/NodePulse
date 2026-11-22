#ifndef NP_SESSION_H
#define NP_SESSION_H
#define SESSION_FRAME (128 * 1024)
static void session_nonce(uint8_t nonce[12], uint64_t seq) {
  memset(nonce, 0, 12);
  for (int i = 0; i < 8; i++) nonce[i] = (uint8_t)(seq >> (8 * i));
}
static int session_seal(uint8_t *out, const uint8_t key[32], uint64_t *seq, const void *plain, size_t n) {
  if (!n || n > SESSION_FRAME || *seq == UINT64_MAX) return -1;
  uint32_t be = htonl((uint32_t)n);
  memcpy(out, &be, 4);
  uint8_t nonce[12]; session_nonce(nonce, *seq);
  crypto_aead_ctx ctx; crypto_aead_init_ietf(&ctx, key, nonce);
  crypto_aead_write(&ctx, out + 4, out + 4 + n, out, 4, plain, n);
  crypto_wipe(&ctx, sizeof(ctx));
  (*seq)++;
  return 0;
}
static int session_open(uint8_t *frame, size_t total, const uint8_t key[32], uint64_t *seq) {
  if (total < 21 || *seq == UINT64_MAX) return -1;
  uint32_t be; memcpy(&be, frame, 4); size_t n = ntohl(be);
  if (!n || n > SESSION_FRAME || total != n + 20) return -1;
  uint8_t nonce[12]; session_nonce(nonce, *seq);
  crypto_aead_ctx ctx; crypto_aead_init_ietf(&ctx, key, nonce);
  int bad = crypto_aead_read(&ctx, frame + 4, frame + 4 + n, frame, 4, frame + 4, n);
  crypto_wipe(&ctx, sizeof(ctx));
  if (bad) return -1;
  (*seq)++;
  return (int)n;
}
#endif
