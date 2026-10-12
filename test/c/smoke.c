/* Builds against the generated header and links libsiv.so. */
#include <siv.h>
#include <stdio.h>

int main(void) {
	uint32_t v = siv_version();
	if (v != SIV_VERSION) {
		fprintf(stderr, "siv_version() = 0x%x, header says 0x%x\n", (unsigned)v, (unsigned)SIV_VERSION);
		return 1;
	}
	return 0;
}
