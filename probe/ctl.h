#ifndef NP_CTL_H
#define NP_CTL_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "dist/installer.h"
#ifndef NPULSE_ARCH
#if defined(__x86_64__)
#define NPULSE_ARCH "x86_64"
#elif defined(__i386__)
#define NPULSE_ARCH "i386"
#elif defined(__aarch64__)
#define NPULSE_ARCH "aarch64"
#elif defined(__mips__)
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define NPULSE_ARCH "mipsel"
#else
#define NPULSE_ARCH "mips"
#endif
#elif defined(__ARM_PCS_VFP)
#define NPULSE_ARCH "armv7"
#else
#define NPULSE_ARCH "armv7-soft"
#endif
#endif
#ifndef NPULSE_CTL_STATE
#define NPULSE_CTL_STATE "/etc/npulse/install.state"
#endif
#ifndef NPULSE_CTL_INIT
#define NPULSE_CTL_INIT "/etc/init.d/npulse"
#endif
#ifndef NPULSE_CTL_SHELL
#define NPULSE_CTL_SHELL "/bin/sh"
#endif
#ifndef NPULSE_CTL_SYSTEMD
#define NPULSE_CTL_SYSTEMD "/usr/bin/systemctl"
#endif
static int ctl(int argc, char **argv) {
  if (argc < 2) return -1;
  const char *op = argv[1];
  if (!strcmp(op, "version")) {
    printf("%s %s %s\n", NPULSE_VERSION, ADMIN ? "full" : "lite", NPULSE_ARCH);
    return 0;
  }
  if (!strcmp(op, "help")) {
    puts("npulse upgrade [--force] | pair | uninstall [--purge] | status | restart | version | help\nManagement options follow install.sh; legacy flags: npulse -h");
    return 0;
  }
  int native = !strcmp(op, "status") || !strcmp(op, "restart");
  if (!native && strcmp(op, "upgrade") && strcmp(op, "pair") && strcmp(op, "uninstall")) return -1;
  char line[128], init[16] = "";
  int managed = 0;
  FILE *f = fopen(NPULSE_CTL_STATE, "r");
  if (f) {
    while (fgets(line, sizeof(line), f)) {
      if (!strcmp(line, "ctl=1\n")) managed = 1;
      if (!strcmp(line, "init=systemd\n")) strcpy(init, "systemd");
      if (!strcmp(line, "init=procd\n")) strcpy(init, "procd");
    }
    fclose(f);
  }
  if (!managed || !*init) {
    fputs("npulse: missing management state; run the latest install.sh upgrade once\n", stderr);
    return 2;
  }
  if (native) {
    if (!strcmp(init, "systemd")) {
      const char *manager = access(NPULSE_CTL_SYSTEMD, X_OK) ? "/bin/systemctl" : NPULSE_CTL_SYSTEMD;
      char **args = calloc((size_t)argc + 2, sizeof(*args));
      if (!args) return 1;
      args[0] = (char *)manager; args[1] = argv[1]; args[2] = "npulse";
      for (int i = 2; i < argc; i++) args[i + 1] = argv[i];
      execv(manager, args);
      free(args);
    }
    else { argv[0] = NPULSE_CTL_INIT; execv(NPULSE_CTL_INIT, argv); }
  } else {
    if (putenv("NPULSE_CURRENT_VERSION=" NPULSE_VERSION)) return 1;
    char **args = calloc((size_t)argc + 4, sizeof(*args));
    if (!args) return 1;
    args[0] = "sh"; args[1] = "-c"; args[2] = (char *)ctl_script; args[3] = "npulse";
    for (int i = 1; i < argc; i++) args[i + 3] = argv[i];
    execv(NPULSE_CTL_SHELL, args);
    free(args);
  }
  perror("npulse management");
  return 1;
}
#endif
