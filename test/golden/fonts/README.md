# Test fonts

Fonts for golden-image tests. The first two are Apache-2.0 (`LICENSE-Apache-2.0.txt`)
and were copied from the HarfBuzz 14.6.0 test suite.

- `Roboto-Regular.ttf`: Roboto 2.137 by Christian Robertson, Google.
  Apache License 2.0 (stated in the font's name table).
- `test_glyphs-glyf_colr_1.ttf`: COLRv1 test glyphs from
  https://github.com/googlefonts/color-fonts, Apache License 2.0.
- `NotoColorEmoji-subset.ttf`: Noto Color Emoji (COLRv1) from
  https://github.com/google/fonts/tree/main/ofl/notocoloremoji, subset
  with fonttools' `pyftsubset --layout-features='*'
  --drop-tables+=SVG,vhea,vmtx --no-hinting` to the emoji the pickers'
  goldens show (Smileys & Emotion, the first 64 People & Body emoji with
  their skin tones, and the emoji chooser's group tabs).
  SIL Open Font License 1.1 (`OFL-NotoColorEmoji.txt`); test data only,
  not shipped.
