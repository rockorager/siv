# The measurement tools: presshim.so (presentation feedback for any client),
# inject (virtual keyboard and pointer), capture (screen frames), and ime
# (a test input method). Needs
# wayland-scanner, wayland-protocols, libwayland-client, and xkbcommon.
CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra
OUT ?= out
WP = $(shell pkg-config --variable=pkgdatadir wayland-protocols)
vpath %.xml protocols $(WP)/stable/presentation-time $(WP)/staging/ext-image-copy-capture $(WP)/staging/ext-image-capture-source \
	$(WP)/staging/ext-foreign-toplevel-list

all: $(OUT)/presshim.so $(OUT)/inject $(OUT)/capture $(OUT)/ime

$(OUT)/gen:
	mkdir -p $@
$(OUT)/gen/%-client-protocol.h: %.xml | $(OUT)/gen
	wayland-scanner client-header $< $@
$(OUT)/gen/%-protocol.c: %.xml | $(OUT)/gen
	wayland-scanner private-code $< $@

$(OUT)/presshim.so: presshim.c $(OUT)/gen/presentation-time-client-protocol.h $(OUT)/gen/presentation-time-protocol.c
	$(CC) $(CFLAGS) -shared -fPIC -I$(OUT)/gen -o $@ presshim.c $(OUT)/gen/presentation-time-protocol.c -lwayland-client -ldl -lpthread

$(OUT)/inject: inject.c $(OUT)/gen/virtual-keyboard-unstable-v1-client-protocol.h $(OUT)/gen/virtual-keyboard-unstable-v1-protocol.c \
		$(OUT)/gen/wlr-virtual-pointer-unstable-v1-client-protocol.h $(OUT)/gen/wlr-virtual-pointer-unstable-v1-protocol.c
	$(CC) $(CFLAGS) -I$(OUT)/gen -o $@ inject.c $(OUT)/gen/virtual-keyboard-unstable-v1-protocol.c \
		$(OUT)/gen/wlr-virtual-pointer-unstable-v1-protocol.c -lwayland-client -lxkbcommon -lm

$(OUT)/capture: capture.c $(OUT)/gen/ext-image-copy-capture-v1-client-protocol.h $(OUT)/gen/ext-image-copy-capture-v1-protocol.c \
		$(OUT)/gen/ext-image-capture-source-v1-client-protocol.h $(OUT)/gen/ext-image-capture-source-v1-protocol.c \
		$(OUT)/gen/ext-foreign-toplevel-list-v1-protocol.c
	$(CC) $(CFLAGS) -I$(OUT)/gen -o $@ capture.c $(OUT)/gen/ext-image-copy-capture-v1-protocol.c \
		$(OUT)/gen/ext-image-capture-source-v1-protocol.c $(OUT)/gen/ext-foreign-toplevel-list-v1-protocol.c -lwayland-client

.PHONY: all

$(OUT)/ime: ime.c $(OUT)/gen/input-method-unstable-v2-client-protocol.h $(OUT)/gen/input-method-unstable-v2-protocol.c
	$(CC) $(CFLAGS) -I$(OUT)/gen -o $@ ime.c $(OUT)/gen/input-method-unstable-v2-protocol.c -lwayland-client
