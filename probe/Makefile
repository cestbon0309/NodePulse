CC = cc
ADMIN ?= 1
HOST_OUT ?= npulse-host
CPPFLAGS += -DADMIN=$(ADMIN)
CFLAGS ?= -Os -flto -std=gnu99 -Wall -Wextra -ffunction-sections -fdata-sections
SOURCES = npulse.c vendor/monocypher.c vendor/monocypher-ed25519.c
HEADERS = json.h metrics.h group.h admin.h vendor/monocypher.h vendor/monocypher-ed25519.h
LDFLAGS ?= -static -Wl,--gc-sections -s

npulse: $(SOURCES) $(HEADERS)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o $@

host-test: $(SOURCES) $(HEADERS)
	$(CC) $(CPPFLAGS) $(CFLAGS) -DNPULSE_ADMIN_TEST=1 $(SOURCES) -Wl,-dead_strip -o $(HOST_OUT)

clean:
	rm -f npulse npulse-host

.PHONY: npulse host-test clean
