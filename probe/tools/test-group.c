#define _GNU_SOURCE
#include "../json.h"
#include "../metrics.h"
#include <assert.h>
static int forbid_metrics;
static int simulated_node;
static void guarded_sample(void) { assert(!forbid_metrics); sample(); }
static void guarded_init(const char *name) {
  assert(!forbid_metrics); metrics_init(name);
  if (simulated_node) identify("", hostname_buf, "fixture-mac", name);
}
#define sample guarded_sample
#define metrics_init guarded_init
#define main npulse_main
#include "../npulse.c"
#undef main
#include <assert.h>
static void matches(Json *j, const char *name, const char *actual) {
  char *expected = string(j, field(j, 0, name));
  assert(expected && !strcmp(expected, actual));
  free(expected);
}
int main(int argc, char **argv) {
  if (argc > 2 && !strcmp(argv[1], "--publisher")) {
    simulated_node = 1;
    return npulse_main(argc - 1, argv + 1);
  }
  if (argc > 2 && !strcmp(argv[1], "--relay-only")) {
    forbid_metrics = 1;
    return npulse_main(argc - 1, argv + 1);
  }
  assert(argc == 2);
  FILE *f = fopen(argv[1], "r");
  assert(f);
  char text[16384];
  size_t n = fread(text, 1, sizeof(text) - 1, f);
  fclose(f);
  text[n] = 0;
  Json j;
  assert(!parse(&j, text));
  group_secret = string(&j, field(&j, 0, "S"));
  group_init();
  matches(&j, "gid", group_id);
  char hex[129], slot[33];
  hex_encode(hex, enc_key, 32);
  matches(&j, "enc_key", hex);
  uint8_t seed[32];
  group_hash(seed, "npulse-e2e-sign:", (const uint8_t *)group_secret, strlen(group_secret));
  hex_encode(hex, seed, 32);
  matches(&j, "seed", hex);
  group_slot(slot, "vector-node");
  matches(&j, "slot", slot);
  char *plain = string(&j, field(&j, 0, "plaintext"));
  char *ad = string(&j, field(&j, 0, "ad"));
  char *nonce = string(&j, field(&j, 0, "nonce"));
  uint8_t sealed[1024];
  assert(!hex_decode(sealed, nonce, 12));
  crypto_aead_ctx ctx;
  crypto_aead_init_ietf(&ctx, enc_key, sealed);
  crypto_aead_write(&ctx, sealed + 12, sealed + 12 + strlen(plain), (const uint8_t *)ad, strlen(ad), (const uint8_t *)plain, strlen(plain));
  char *blob = base64_encode(sealed, strlen(plain) + 28);
  matches(&j, "blob", blob);
  const char *messages[] = {"message", "gget_message"};
  const char *signatures[] = {"signature", "gget_signature"};
  for (int i = 0; i < 2; i++) {
    char *message = string(&j, field(&j, 0, messages[i]));
    uint8_t sig[64];
    crypto_ed25519_sign(sig, signing_key, (const uint8_t *)message, strlen(message));
    hex_encode(hex, sig, 64);
    matches(&j, signatures[i], hex);
    free(message);
  }
  groups[0].slots[0].blob = strdup("expired");
  strcpy(groups[0].slots[0].slot, slot);
  groups[0].slots[0].seen = 1;
  strcpy(groups[0].gid, group_id);
  group_expire(602);
  assert(!groups[0].gid[0] && !groups[0].slots[0].blob);
  assert(4 * ((MAX_NODE_JSON + 28 + 2) / 3) == 5160);
  free((void *)group_secret); free(plain); free(ad); free(nonce); free(blob);
  puts("PASS C/Ed25519/ChaChaPoly fixed cross-language vector, snapshot budget and TTL eviction");
  return 0;
}
