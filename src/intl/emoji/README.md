# Emoji data

`emoji-test.txt` is UTS #51's emoji keyboard and display test data for
Emoji 18.0, unchanged, from
https://www.unicode.org/Public/18.0.0/emoji/emoji-test.txt
(SHA-256 8f3735cda1f92a779d78af67cf86066bb1f07143dc22f2ac29394d9bc57ab21a).
It is kept here because unicode.org publishes it as a plain text file,
which Zig's package manager cannot fetch, and no archive carries it.

`src/intl/gen.zig` reads it at build time and writes the emoji catalogue
(every fully-qualified emoji without a skin tone, in CLDR order, with its
group, name, and skin tone variants) into libsiv (D41).

© 2026 Unicode, Inc. Unicode License v3 (`src/notices/unicode-LICENSE.txt`).
