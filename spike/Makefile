SIV ?= /root/siv/zig-out
PKGS = wpe-webkit-2.0 wpe-platform-2.0 gbm egl epoxy
CFLAGS ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
out/spike: spike.c
	@mkdir -p out
	$(CC) $(CFLAGS) -I$(SIV)/include $(shell pkg-config --cflags $(PKGS)) -o $@ $< -L$(SIV)/lib -lsiv -Wl,-rpath,$(SIV)/lib $(shell pkg-config --libs $(PKGS))
clean:
	rm -rf out
