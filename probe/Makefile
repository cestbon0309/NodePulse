CC = cc
ADMIN ?= 1
PAIR ?= $(ADMIN)
QR ?= $(PAIR)
HOST_OUT ?= npulse-host
CPPFLAGS += -DADMIN=$(ADMIN) -DPAIR=$(PAIR) -DQR=$(QR)
CFLAGS ?= -Os -flto -std=gnu99 -Wall -Wextra -ffunction-sections -fdata-sections
SOURCES = npulse.c vendor/monocypher.c vendor/monocypher-ed25519.c vendor/qrcodegen.c
HEADERS = json.h metrics.h history.h egress.h upstream.h group.h admin.h pipe.h session.h pairing.h vendor/monocypher.h vendor/monocypher-ed25519.h vendor/qrcodegen.h
LDFLAGS ?= -static -Wl,--gc-sections -s

npulse: $(SOURCES) $(HEADERS)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o $@

host-test: $(SOURCES) $(HEADERS)
	$(CC) $(CPPFLAGS) $(CFLAGS) -DNPULSE_ADMIN_TEST=1 $(SOURCES) -Wl,-dead_strip -o $(HOST_OUT)

clean:
	rm -f npulse npulse-host

history-test: host-test
	mkdir -p dist
	$(CC) -std=gnu99 -Wall -Wextra -Werror tools/test-history.c -o dist/test-history
	./dist/test-history
	$(CC) -DADMIN=0 -DPAIR=0 -DQR=0 $(CFLAGS) tools/test-history-server.c vendor/monocypher.c vendor/monocypher-ed25519.c vendor/qrcodegen.c -Wl,-dead_strip -o dist/history-server
	python3 tools/test-history.py ./$(HOST_OUT) ./dist/history-server

.PHONY: npulse host-test history-test clean
