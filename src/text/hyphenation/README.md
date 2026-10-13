# Hyphenation patterns

TeX hyphenation patterns from hyph-utf8 (https://github.com/hyphenation/tex-hyphen,
commit 5684c0f51c0b81133db2efbe60a408b4155a3ff5, 2026-02-24), the `txt`
conversions of the files below. Each `hyph-<tag>.lic.txt` is the header of the
pattern file it came from: its copyright, licence, and hyphenmins. Only files
whose licence is MIT, BSD, or as permissive are kept (D25); siv reads them with
the typesetting hyphenmins their headers give. `LICENSE-MIT.txt` gives the MIT
text for the headers that name the licence without it. All of these go into
libsiv's NOTICES (src/notices/build_steps.zig).

| Tag | Language | Licence |
| --- | --- | --- |
| en-us | English, American spelling | FSF all-permissive ("Copying and distribution of this file, with or without modification, are permitted in any medium without royalty provided the copyright notice and this notice are preserved.") |
| en-gb | English, British spelling | MIT |
| de-1996 | German, 1996 spelling | MIT |
| fr | French | MIT |
| es | Spanish | MIT/X11 |
| nl | Dutch | MIT |
| pt | Portuguese | BSD 3-clause |
| pl | Polish | MIT (or others, at the user's choice) |
| uk | Ukrainian | MIT (or LPPL, at the user's choice) |
| sk | Slovak | MIT |

Left out for their licences (LPPL, GPL, LGPL, MPL, or terms of their own),
among others: Catalan, Czech, Danish, Greek, Italian, Russian, Swedish,
Hungarian, Latvian, Bulgarian, Basque, Finnish, Norwegian, Romanian.
Applications add patterns for those with `siv_app_add_hyphenation`.
