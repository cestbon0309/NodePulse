#define main npulse_main
#include "../npulse.c"
#undef main
#include <assert.h>
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--pair-host")) {
    char host[256]; listen_addr = "127.0.0.1:9527"; pair_host(host); puts(host); return 0;
  }
  uint8_t decoded[3];
  assert(!hex_decode(decoded, "00aBcD", 3));
  assert(decoded[0] == 0 && decoded[1] == 0xab && decoded[2] == 0xcd);
  assert(hex_decode(decoded, NULL, 3) && hex_decode(decoded, "", 3));
  assert(hex_decode(decoded, "00abc", 3) && hex_decode(decoded, "00abcz", 3));
  if (argc == 2 && !strcmp(argv[1], "--pair-timers")) {
    pipe_init(); int sockets[65][2]; double now = monotime();
    for (int i = 0; i < 65; i++) {
      assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, sockets[i]));
      char json[160]; snprintf(json, sizeof(json), "{\"op\":\"ppair\",\"v\":1,\"rid\":\"%032x\"}", i + 1);
      Json j; assert(!parse(&j, json));
      assert(pair_pipe_request(&j, time(NULL), sockets[i][0]) == (i < 64 ? 1 : 0));
    }
    pipe_tick(now + 601);
    for (int i = 0; i < PIPE_SOCKETS; i++) assert(relay_pipes[i].mode != RP_PAIR);
    for (int i = 0; i < 64; i++) { char byte; assert(recv(sockets[i][1], &byte, 1, 0) == 0); close(sockets[i][1]); }
    close(sockets[64][0]); close(sockets[64][1]); pipe_shutdown();
    puts("PASS relay pair simulated timers/capacity: exactly 64 pending codes, 65th refused; all expire after 600 seconds and close sockets"); return 0;
  }
  if (argc != 2 || strcmp(argv[1], "--vector")) return npulse_main(argc, argv);
  uint8_t sk[32], peer_sk[32], pub[32], peer[32], shared[32], k[64], hash[64];
  for (int i = 0; i < 32; i++) { sk[i] = (uint8_t)(i + 1); peer_sk[i] = (uint8_t)(i + 33); }
  crypto_x25519_public_key(pub, sk); crypto_x25519_public_key(peer, peer_sk);
  crypto_x25519(shared, sk, peer);
  pair_hash(k, "npulse-pair", shared, 32, pub, 32, peer, 32);
  Buffer b = buffer(); char hex[129];
  hex_encode(hex, pub, 32); add(&b, "{\"epk_c\":\"%s\",", hex);
  hex_encode(hex, peer, 32); add(&b, "\"epk_p\":\"%s\",", hex);
  pair_hash(hash, "npulse-pair-commit", pub, 32, NULL, 0, NULL, 0);
  hex_encode(hex, hash, 32); add(&b, "\"commit\":\"%s\",", hex);
  hex_encode(hex, k, 64); add(&b, "\"k\":\"%s\",", hex);
  pair_hash(hash, "npulse-pair-sas", k, 64, NULL, 0, NULL, 0);
  hex_encode(hex, hash, 16); add(&b, "\"sas\":\"%s\",\"art\":", hex);
  char art[221]; pair_art(art, hash); quote(&b, art);
  uint32_t code = ((uint32_t)hash[0] << 24 | (uint32_t)hash[1] << 16 | (uint32_t)hash[2] << 8 | hash[3]) % 1000000;
  add(&b, ",\"code\":\"%03u %03u\"", code / 1000, code % 1000);
  uint8_t psk[16]; for (int i = 0; i < 16; i++) psk[i] = (uint8_t)i;
  pair_derive(k, shared, pub, peer, psk); hex_encode(hex, k, 64); add(&b, ",\"k_psk\":\"%s\"", hex);
  pair_hash(hash, "npulse-pair-sas", k, 64, NULL, 0, NULL, 0); hex_encode(hex, hash, 16); add(&b, ",\"sas_psk\":\"%s\"}", hex);
  puts(b.s); free(b.s);
  return 0;
}
