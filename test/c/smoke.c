/* Builds against the generated header and links libsiv.so. The ABI
 * conventions themselves are exercised by abi.c. */
#include <siv.h>
#include <stdio.h>
#include <string.h>

int main(void) {
	int failed = 0;
	uint32_t v = siv_version();
	if (v != SIV_VERSION) {
		fprintf(stderr, "siv_version() = 0x%x, header says 0x%x\n", (unsigned)v, (unsigned)SIV_VERSION);
		failed = 1;
	}
	if (strcmp(siv_result_name(SIV_ERROR_INVALID_HANDLE), "SIV_ERROR_INVALID_HANDLE") != 0 ||
	    strcmp(siv_result_name((siv_result)12345), "SIV_RESULT_UNKNOWN") != 0) {
		fprintf(stderr, "siv_result_name is wrong\n");
		failed = 1;
	}
	const siv_allocator *defaults = SIV_DESC(siv_allocator, .user_data = NULL);
	if (defaults->size != sizeof(siv_allocator) || defaults->alloc != NULL) failed = 1;
	return failed;
}
