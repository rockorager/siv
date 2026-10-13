/* Shared constants and content of the benchmark scenarios. gpui/src/spec.rs
 * mirrors this file; keep the two identical. */
#ifndef BENCH_DOC_H
#define BENCH_DOC_H

#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#define BENCH_FONT "Adwaita Sans"
/* siv's body text: 11 pt. */
#define BODY_PX (11.0f * 4.0f / 3.0f)
#define DOC_LINE_HEIGHT 20.0f
#define DOC_LARGE_PARAGRAPHS 4000
#define DOC_SMALL_PARAGRAPHS 6
/* The word F3 searches for: once, three quarters of the way through the
 * document and the log. */
#define DOC_NEEDLE "haystackneedle"
/* The log scenario's size. */
#define LOG_BYTES (100u << 20)

#define GRID_COLS 64
#define GRID_ROWS 40
#define GRID_PERIOD_MS 1000

static inline uint32_t grid_delay_ms(int i) { return (uint32_t)((i * 7) % 20) * 50; }

static inline uint32_t grid_color(int i) {
	static const uint32_t colors[] = {0x2563eb, 0xdc2626, 0x16a34a, 0xd97706, 0x9333ea, 0x0891b2};
	return colors[(i / 3) % 6];
}

static const char *const doc_words[] = {
	"the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "toolkit", "render", "frame", "layout",
	"window", "surface", "glyph", "shaping", "paragraph", "compositor", "latency", "buffer", "pixel", "vector",
	"linear", "light", "scroll", "list", "button", "menu", "editor", "caret", "selection", "input", "method",
	"wayland", "vulkan", "thread", "queue", "present", "damage", "region", "tile", "atlas", "texture", "shader",
	"and", "of", "to", "in", "is", "that", "with", "for", "as", "on", "by", "at", "from", "it", "an", "be",
	"this", "which", "or", "are",
};

static inline uint32_t doc_next(uint64_t *state) {
	*state = *state * 6364136223846793005ull + 1442695040888963407ull;
	return (uint32_t)(*state >> 33);
}

/* Paragraphs of 20 to 99 words separated by '\n'; the caller frees. */
static inline char *doc_generate(size_t paragraphs, size_t *len_out) {
	uint64_t state = 12345;
	size_t cap = paragraphs * 800 + 1, len = 0;
	char *out = malloc(cap);
	for (size_t p = 0; p < paragraphs; p++) {
		uint32_t words = 20 + doc_next(&state) % 80;
		for (uint32_t w = 0; w < words; w++) {
			const char *word = doc_words[doc_next(&state) % (sizeof doc_words / sizeof doc_words[0])];
			size_t n = strlen(word);
			if (w > 0) out[len++] = ' ';
			memcpy(out + len, word, n);
			if (w == 0) out[len] = (char)(out[len] - 'a' + 'A');
			len += n;
		}
		if (p == paragraphs * 3 / 4) {
			memcpy(out + len, " " DOC_NEEDLE, sizeof DOC_NEEDLE);
			len += sizeof DOC_NEEDLE;
		}
		out[len++] = '.';
		if (p + 1 < paragraphs) out[len++] = '\n';
	}
	out[len] = 0;
	*len_out = len;
	return out;
}

static const char *const log_levels[] = {"INFO ", "INFO ", "INFO ", "DEBUG", "WARN ", "ERROR"};

/* One log line of about 100 bytes, without its line break, into buf
 * (at least 160 bytes); returns its length. */
static inline size_t log_line(uint64_t *state, size_t i, char *buf) {
	uint32_t t = (uint32_t)i;
	uint32_t ms = doc_next(state) % 1000, worker = doc_next(state) % 16, item = doc_next(state) % 100000, took = doc_next(state) % 500;
	const char *level = log_levels[doc_next(state) % 6];
	const char *what = doc_words[doc_next(state) % (sizeof doc_words / sizeof doc_words[0])];
	int n = snprintf(buf, 160, "2026-10-13 %02u:%02u:%02u.%03u %s [worker-%02u] GET /api/v1/%s/%05u served in %u ms (request %zu)", t / 3600000 % 24, t / 60000 % 60,
	                 t / 1000 % 60, ms, level, worker, what, item, took, i);
	return (size_t)n;
}

/* Log lines up to about LOG_BYTES, the needle three quarters of the way
 * in; the caller frees. */
static inline char *log_generate(size_t *len_out, size_t *lines_out) {
	uint64_t state = 777;
	size_t cap = LOG_BYTES + 256, len = 0, i = 0;
	char *out = malloc(cap);
	char line[160];
	while (len < LOG_BYTES) {
		if (i > 0) out[len++] = '\n';
		size_t n = log_line(&state, i, line);
		memcpy(out + len, line, n);
		len += n;
		if (len >= LOG_BYTES * 3 / 4 && len - n < LOG_BYTES * 3 / 4) {
			memcpy(out + len, " " DOC_NEEDLE, sizeof DOC_NEEDLE);
			len += sizeof DOC_NEEDLE;
		}
		i++;
	}
	out[len] = 0;
	*len_out = len;
	*lines_out = i;
	return out;
}

#endif
