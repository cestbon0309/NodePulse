#define main probe_main
#include "../npulse.c"
#undef main
#include <assert.h>
static char input[16384];
int main(int argc, char **argv) {
  assert(argc == 3);
  FILE *file = fopen(argv[2], "r"); assert(file);
  size_t size = fread(input, 1, sizeof(input) - 1, file); fclose(file);
  Json j; assert(!parse(&j, input));
  if (!strcmp(argv[1], "--verify")) {
    assert(field(&j, 0, "since") >= 0);
    long long stamp = strtoll(input + j.t[field(&j, 0, "ts")].start, NULL, 10);
    char *response = group_request(&j, stamp, (time_t)stamp);
    assert(response); free(response);
    puts("PASS C relay verified the actual CryptoKit history request signature and serialized since map");
    return 0;
  }
  assert(!strcmp(argv[1], "--generate"));
  group_secret = string(&j, field(&j, 0, "S")); group_init();
  char slot[33], sig[129]; uint8_t signature[64]; group_slot(slot, "vector-node");
  Buffer map = buffer(); add(&map, "{\"%s\":{\"epoch\":\"1234567890abcdef\",\"since\":1}}", slot);
  Buffer message = buffer(); add(&message, "npulse-gget\n%s\n1700000000\n00112233445566778899aabbccddeeff\n%s", group_id, map.s);
  crypto_ed25519_sign(signature, signing_key, (const uint8_t *)message.s, message.n);
  hex_encode(sig, signature, sizeof(signature));
  Buffer request = buffer(); add(&request, "{\"op\":\"gget\",\"ts\":1700000000,\"rid\":\"00112233445566778899aabbccddeeff\",\"gid\":\"%s\",\"since\":%s,\"sig\":\"%s\"}", group_id, map.s, sig);
  Json check; assert(!parse(&check, request.s));
  char *verified = group_request(&check, 1700000000, 1700000000); assert(verified); free(verified);
  Buffer output = buffer();
  add(&output, "%.*s,\n  \"history_message\":", j.t[0].end - 1, input); quote(&output, message.s);
  add(&output, ",\n  \"history_signature\":"); quote(&output, sig);
  add(&output, ",\n  \"history_request\":"); quote(&output, request.s); add(&output, "\n}\n");
  fputs(output.s, stdout);
  free((void *)group_secret); free(map.s); free(message.s); free(request.s); free(output.s);
}
