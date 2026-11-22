CC = cc
CFLAGS ?= -Os -flto -std=gnu99 -Wall -Wextra -ffunction-sections -fdata-sections
SOURCES = npulse.c vendor/monocypher.c vendor/monocypher-ed25519.c
HEADERS = json.h metrics.h vendor/monocypher.h vendor/monocypher-ed25519.h
LDFLAGS ?= -static -Wl,--gc-sections -s

npulse: $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o $@

host-test: $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(SOURCES) -Wl,-dead_strip -o npulse-host

clean:
	rm -f npulse npulse-host

.PHONY: host-test clean
