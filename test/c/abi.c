/* Exercises the ABI conventions (DESIGN.md D2) through libsiv-abitest, a
 * test library built from src/abi/test_api.zig with the same generators,
 * runtime, and link setup as libsiv. */
#include <sivtest.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(cond)                                                       \
	do {                                                                  \
		if (!(cond)) {                                                    \
			fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #cond); \
			failures++;                                                   \
		}                                                                 \
	} while (0)

#define EXPECT(call, want)                                                \
	do {                                                                  \
		siv_result r_ = (call);                                           \
		if (r_ != (want)) {                                               \
			fprintf(stderr, "%s:%d: %s returned %d, expected %d\n", __FILE__, __LINE__, #call, (int)r_, (int)(want)); \
			failures++;                                                   \
		}                                                                 \
	} while (0)

/* Allocator hooks that count live memory and can fail the nth allocation. */
struct counter {
	size_t live_bytes;
	size_t live_blocks;
	size_t attempts;
	size_t fail_at; /* attempt number to fail; SIZE_MAX for none */
	int bad_args;
};

static void *count_alloc(void *user_data, size_t size, size_t alignment) {
	struct counter *c = user_data;
	if (c->attempts++ == c->fail_at) return NULL;
	if (size == 0 || alignment == 0 || (alignment & (alignment - 1)) != 0) c->bad_args = 1;
	size_t a = alignment < sizeof(void *) ? sizeof(void *) : alignment;
	void *p = aligned_alloc(a, (size + a - 1) / a * a);
	if (p == NULL) return NULL;
	c->live_bytes += size;
	c->live_blocks++;
	return p;
}

static void count_free(void *user_data, void *ptr, size_t size, size_t alignment) {
	struct counter *c = user_data;
	(void)alignment;
	if (ptr == NULL) c->bad_args = 1;
	c->live_bytes -= size;
	c->live_blocks--;
	free(ptr);
}

static struct counter counter_init(void) {
	struct counter c = {0};
	c.fail_at = SIZE_MAX;
	return c;
}

static sivtest_context counted_context(struct counter *c) {
	sivtest_context ctx = 0;
	EXPECT(sivtest_context_create(SIVTEST_DESC(sivtest_context_desc,
	                                  .allocator = SIVTEST_DESC(siv_allocator, .user_data = c, .alloc = count_alloc, .free = count_free)),
	                              &ctx),
	       SIV_OK);
	return ctx;
}

static void test_defaults(void) {
	sivtest_context ctx = 0;
	EXPECT(sivtest_context_create(NULL, &ctx), SIV_OK);
	CHECK(ctx != 0);

	/* NULL descriptor: every field takes its default. */
	sivtest_item item = 0;
	EXPECT(sivtest_item_create(ctx, NULL, &item), SIV_OK);
	sivtest_item_info info;
	EXPECT(sivtest_item_get(item, &info), SIV_OK);
	CHECK(info.shape == SIVTEST_SHAPE_SQUARE);
	CHECK(info.flags == 0);
	CHECK(info.weight == 1);
	CHECK(info.name_len == 0);

	/* Designated initializers: unnamed fields are zero, so default. */
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .shape = SIVTEST_SHAPE_STAR, .flags = SIVTEST_ITEM_PINNED, .origin = {1.5f, -2.0f}, .weight = 9), &item),
	       SIV_OK);
	EXPECT(sivtest_item_get(item, &info), SIV_OK);
	CHECK(info.shape == SIVTEST_SHAPE_STAR);
	CHECK(info.flags == SIVTEST_ITEM_PINNED);
	CHECK(info.origin.x == 1.5f && info.origin.y == -2.0f);
	CHECK(info.weight == 9);
	CHECK(sivtest_context_item_count(ctx) == 2);

	EXPECT(sivtest_context_destroy(ctx), SIV_OK);
}

static void test_descriptor_sizes(void) {
	sivtest_context ctx = 0;
	EXPECT(sivtest_context_create(NULL, &ctx), SIV_OK);
	sivtest_item item = 0;
	sivtest_item_info info;

	/* A caller built against headers from before `weight` existed: the
	 * library must not read past the size it was given. */
	sivtest_item_desc old;
	memset(&old, 0xff, sizeof old);
	old.size = offsetof(sivtest_item_desc, weight);
	old.name = NULL;
	old.name_len = 0;
	old.shape = SIVTEST_SHAPE_CIRCLE;
	old.flags = 0;
	old.origin.x = old.origin.y = 0;
	EXPECT(sivtest_item_create(ctx, &old, &item), SIV_OK);
	EXPECT(sivtest_item_get(item, &info), SIV_OK);
	CHECK(info.shape == SIVTEST_SHAPE_CIRCLE);
	CHECK(info.weight == 1);

	/* A caller built against newer headers with a field this library does
	 * not know: fine when zero, unsupported when set. */
	struct newer {
		sivtest_item_desc base;
		uint64_t future;
	} newer;
	memset(&newer, 0, sizeof newer);
	newer.base.size = sizeof newer;
	newer.base.weight = 4;
	EXPECT(sivtest_item_create(ctx, &newer.base, &item), SIV_OK);
	EXPECT(sivtest_item_get(item, &info), SIV_OK);
	CHECK(info.weight == 4);
	newer.future = 1;
	EXPECT(sivtest_item_create(ctx, &newer.base, &item), SIV_ERROR_UNSUPPORTED);

	/* Sizes no version ever had. */
	sivtest_item_desc bad = {0};
	EXPECT(sivtest_item_create(ctx, &bad, &item), SIV_ERROR_INVALID_ARGUMENT); /* size 0 */
	bad.size = offsetof(sivtest_item_desc, weight) + 4;
	EXPECT(sivtest_item_create(ctx, &bad, &item), SIV_ERROR_INVALID_ARGUMENT);

	/* Nested descriptors are checked the same way. */
	siv_allocator alloc = {0};
	alloc.size = 3;
	sivtest_context other = 0;
	EXPECT(sivtest_context_create(SIVTEST_DESC(sivtest_context_desc, .allocator = &alloc), &other), SIV_ERROR_INVALID_ARGUMENT);
	/* Allocator hooks are both or neither. */
	EXPECT(sivtest_context_create(SIVTEST_DESC(sivtest_context_desc, .allocator = SIVTEST_DESC(siv_allocator, .alloc = count_alloc)), &other),
	       SIV_ERROR_INVALID_ARGUMENT);
	CHECK(other == 0);

	CHECK(sivtest_context_item_count(ctx) == 2);
	EXPECT(sivtest_context_destroy(ctx), SIV_OK);
}

static void test_enums_and_flags(void) {
	sivtest_context ctx = 0;
	EXPECT(sivtest_context_create(NULL, &ctx), SIV_OK);
	sivtest_item item = 0;
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .shape = (sivtest_shape)2), &item), SIV_ERROR_UNSUPPORTED);
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .flags = (sivtest_item_flags)1u << 1), &item), SIV_ERROR_UNSUPPORTED);
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .flags = (sivtest_item_flags)1u << 31), &item), SIV_ERROR_UNSUPPORTED);
	/* Failed calls have no effect. */
	CHECK(item == 0);
	CHECK(sivtest_context_item_count(ctx) == 0);
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .flags = SIVTEST_ITEM_HIDDEN | SIVTEST_ITEM_PINNED), &item), SIV_OK);
	EXPECT(sivtest_context_destroy(ctx), SIV_OK);
}

struct visit_log {
	int calls;
	int stop_after;
	char names[8][8];
	size_t lens[8];
	sivtest_item items[8];
};

static bool record(void *user_data, sivtest_item item, const char *name, size_t name_len) {
	struct visit_log *log = user_data;
	if (log->calls < 8 && name_len <= 8) {
		memcpy(log->names[log->calls], name, name_len);
		log->lens[log->calls] = name_len;
		log->items[log->calls] = item;
	}
	log->calls++;
	return log->calls != log->stop_after;
}

static void test_strings_and_callbacks(void) {
	sivtest_context ctx = 0;
	EXPECT(sivtest_context_create(NULL, &ctx), SIV_OK);

	char buf[] = {'a', '\0', 'b'};
	sivtest_item a = 0, b = 0, hidden = 0, c = 0;
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .name = buf, .name_len = sizeof buf), &a), SIV_OK);
	buf[0] = 'X'; /* the library copied the name */
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .name = "bee", .name_len = 3), &b), SIV_OK);
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .name = "h", .name_len = 1, .flags = SIVTEST_ITEM_HIDDEN), &hidden), SIV_OK);
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .name = NULL, .name_len = 0), &c), SIV_OK);
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .name = NULL, .name_len = 5), &c), SIV_ERROR_INVALID_ARGUMENT);

	/* Not NUL-terminated: only name_len bytes are read. */
	char unterminated[4] = {'q', 'r', 's', 't'};
	EXPECT(sivtest_item_set_name(b, unterminated, 2), SIV_OK);

	struct visit_log log = {0};
	uint32_t visited = 0;
	EXPECT(sivtest_context_visit(ctx, record, &log, &visited), SIV_OK);
	CHECK(visited == 3 && log.calls == 3);
	CHECK(log.items[0] == a && log.lens[0] == 3 && memcmp(log.names[0], "a\0b", 3) == 0);
	CHECK(log.items[1] == b && log.lens[1] == 2 && memcmp(log.names[1], "qr", 2) == 0);
	CHECK(log.items[2] == c && log.lens[2] == 0);

	/* The callback's return value stops the iteration. */
	memset(&log, 0, sizeof log);
	log.stop_after = 1;
	EXPECT(sivtest_context_visit(ctx, record, &log, &visited), SIV_OK);
	CHECK(visited == 1 && log.calls == 1);

	EXPECT(sivtest_context_visit(ctx, NULL, &log, &visited), SIV_ERROR_INVALID_ARGUMENT);
	EXPECT(sivtest_context_visit(ctx, record, &log, NULL), SIV_ERROR_INVALID_ARGUMENT);

	/* Destroying an item keeps the others' handles valid and in order. */
	EXPECT(sivtest_item_destroy(a), SIV_OK);
	memset(&log, 0, sizeof log);
	EXPECT(sivtest_context_visit(ctx, record, &log, &visited), SIV_OK);
	CHECK(visited == 2 && log.items[0] == b && log.items[1] == c);
	sivtest_item_info info;
	EXPECT(sivtest_item_get(hidden, &info), SIV_OK);
	CHECK(info.flags == SIVTEST_ITEM_HIDDEN && info.name_len == 1);

	EXPECT(sivtest_context_destroy(ctx), SIV_OK);
}

static void test_handles(void) {
	sivtest_context ctx = 0, other = 0;
	EXPECT(sivtest_context_create(NULL, &ctx), SIV_OK);
	EXPECT(sivtest_context_create(NULL, &other), SIV_OK);
	CHECK(ctx != other);

	sivtest_item item = 0, item2 = 0, foreign = 0;
	EXPECT(sivtest_item_create(ctx, NULL, &item), SIV_OK);
	EXPECT(sivtest_item_create(ctx, NULL, &item2), SIV_OK);
	EXPECT(sivtest_item_create(other, NULL, &foreign), SIV_OK);
	sivtest_item_info info;

	/* Null, mistyped, and garbage handles. */
	EXPECT(sivtest_item_get(0, &info), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_get((sivtest_item)ctx, &info), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_context_destroy((sivtest_context)item), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_create((sivtest_context)item, NULL, &item2), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_get(UINT64_MAX, &info), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_get(item + 1000, &info), SIV_ERROR_INVALID_HANDLE); /* index past the table */
	EXPECT(sivtest_item_get(item ^ ((uint64_t)1 << 24), &info), SIV_ERROR_INVALID_HANDLE); /* generation */
	EXPECT(sivtest_item_get(item ^ ((uint64_t)1 << 46), &info), SIV_ERROR_INVALID_HANDLE); /* root slot */
	CHECK(sivtest_context_item_count(0) == 0);

	/* NULL out pointer: invalid, and nothing was created. */
	EXPECT(sivtest_item_create(ctx, NULL, NULL), SIV_ERROR_INVALID_ARGUMENT);
	EXPECT(sivtest_item_get(item, NULL), SIV_ERROR_INVALID_ARGUMENT);
	CHECK(sivtest_context_item_count(ctx) == 2);

	/* Stale handles. */
	EXPECT(sivtest_item_destroy(item), SIV_OK);
	EXPECT(sivtest_item_get(item, &info), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_destroy(item), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_set_name(item, "x", 1), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_get(item2, &info), SIV_OK);

	/* A slot reused many times never revives an old handle. */
	for (int i = 0; i < 3000; i++) {
		sivtest_item tmp = 0;
		EXPECT(sivtest_item_create(ctx, NULL, &tmp), SIV_OK);
		CHECK(tmp != item);
		EXPECT(sivtest_item_destroy(tmp), SIV_OK);
	}
	EXPECT(sivtest_item_get(item, &info), SIV_ERROR_INVALID_HANDLE);

	/* Destroying a root invalidates it and its objects, not other roots. */
	EXPECT(sivtest_context_destroy(ctx), SIV_OK);
	EXPECT(sivtest_context_destroy(ctx), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_get(item2, &info), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_destroy(item2), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_item_get(foreign, &info), SIV_OK);

	/* A new root, possibly in the same registry slot, does not accept the
	 * old root's handles. */
	sivtest_context again = 0;
	EXPECT(sivtest_context_create(NULL, &again), SIV_OK);
	CHECK(again != ctx);
	EXPECT(sivtest_item_get(item2, &info), SIV_ERROR_INVALID_HANDLE);
	EXPECT(sivtest_context_destroy(again), SIV_OK);
	EXPECT(sivtest_context_destroy(other), SIV_OK);
}

static void test_allocator_hooks(void) {
	struct counter c = counter_init();
	sivtest_context ctx = counted_context(&c);
	CHECK(c.live_blocks > 0); /* the context itself comes from the hooks */
	for (int i = 0; i < 100; i++) {
		sivtest_item item = 0;
		EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .name = "name", .name_len = 4), &item), SIV_OK);
		if (i % 3 == 0) EXPECT(sivtest_item_destroy(item), SIV_OK);
	}
	EXPECT(sivtest_context_destroy(ctx), SIV_OK);
	CHECK(c.live_bytes == 0 && c.live_blocks == 0);
	CHECK(!c.bad_args);
}

/* Every allocation of every call can fail; each failure returns
 * SIV_ERROR_OUT_OF_MEMORY, leaves no trace, and leaks nothing. */
static void test_allocation_failure(void) {
	struct counter c = counter_init();
	sivtest_context_desc desc = {sizeof desc, NULL};
	siv_allocator hooks = {sizeof hooks, &c, count_alloc, count_free};
	desc.allocator = &hooks;

	size_t n;
	for (n = 0;; n++) {
		c.attempts = 0;
		c.fail_at = n;
		sivtest_context ctx = 42;
		siv_result r = sivtest_context_create(&desc, &ctx);
		if (r == SIV_OK) {
			EXPECT(sivtest_context_destroy(ctx), SIV_OK);
			break;
		}
		EXPECT(r, SIV_ERROR_OUT_OF_MEMORY);
		CHECK(ctx == 42);
		CHECK(c.live_blocks == 0);
	}
	CHECK(n >= 1);

	for (n = 0;; n++) {
		c.fail_at = SIZE_MAX;
		sivtest_context ctx = counted_context(&c);
		c.attempts = 0;
		c.fail_at = n;
		sivtest_item item = 42;
		siv_result r = sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .name = "n", .name_len = 1), &item);
		if (r == SIV_OK) {
			EXPECT(sivtest_context_destroy(ctx), SIV_OK);
			CHECK(c.live_blocks == 0);
			break;
		}
		EXPECT(r, SIV_ERROR_OUT_OF_MEMORY);
		CHECK(item == 42);
		CHECK(sivtest_context_item_count(ctx) == 0);
		/* Capacity reserved before the failure may stay until the
		 * context is destroyed; nothing else may. */
		EXPECT(sivtest_context_destroy(ctx), SIV_OK);
		CHECK(c.live_blocks == 0);
	}
	CHECK(n >= 3); /* name, item list, handle table */

	c.fail_at = SIZE_MAX;
	sivtest_context ctx = counted_context(&c);
	sivtest_item item = 0;
	EXPECT(sivtest_item_create(ctx, SIVTEST_DESC(sivtest_item_desc, .name = "old", .name_len = 3), &item), SIV_OK);
	c.attempts = 0;
	c.fail_at = 0;
	EXPECT(sivtest_item_set_name(item, "newer", 5), SIV_ERROR_OUT_OF_MEMORY);
	sivtest_item_info info;
	EXPECT(sivtest_item_get(item, &info), SIV_OK);
	CHECK(info.name_len == 3);
	c.fail_at = SIZE_MAX;
	EXPECT(sivtest_context_destroy(ctx), SIV_OK);
	CHECK(c.live_bytes == 0 && c.live_blocks == 0);
}

static void test_root_limit(void) {
	/* Roots are limited per process; the limit is an error, not a crash. */
	enum { max = 1024 };
	static sivtest_context roots[max + 1];
	int made = 0;
	siv_result r = SIV_OK;
	while (made <= max && (r = sivtest_context_create(NULL, &roots[made])) == SIV_OK) made++;
	EXPECT(r, SIV_ERROR_LIMIT_EXCEEDED);
	CHECK(made == max);
	for (int i = 0; i < made; i++) EXPECT(sivtest_context_destroy(roots[i]), SIV_OK);
	EXPECT(sivtest_context_create(NULL, &roots[0]), SIV_OK);
	EXPECT(sivtest_context_destroy(roots[0]), SIV_OK);
}

int main(void) {
	test_defaults();
	test_descriptor_sizes();
	test_enums_and_flags();
	test_strings_and_callbacks();
	test_handles();
	test_allocator_hooks();
	test_allocation_failure();
	test_root_limit();
	if (failures) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	return 0;
}
