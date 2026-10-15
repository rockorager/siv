//! The user-agent stylesheet: HTML's rendering section (WHATWG HTML 15)
//! for the elements documents use. Colors are system colors (Canvas,
//! CanvasText, LinkText, ...), which the renderer resolves from the
//! application's theme when it paints (D29), so a theme change repaints
//! without restyling.

pub const css =
    \\@namespace url(http://www.w3.org/1999/xhtml);
    \\html, address, blockquote, body, center, dialog, div, figure, figcaption, footer, form, header, hr,
    \\legend, listing, main, p, plaintext, pre, search, xmp, details, summary, article, aside, h1, h2, h3,
    \\h4, h5, h6, hgroup, nav, section, dir, dd, dl, dt, menu, ol, ul, li, fieldset, optgroup, option { display: block }
    \\area, base, basefont, datalist, head, link, meta, noembed, noframes, param, rp, script, style, template,
    \\title, [hidden]:not([hidden=until-found i]), noscript, embed[hidden], dialog:not([open]) { display: none }
    \\html { color: CanvasText; line-height: normal }
    \\body { margin: 8px }
    \\address, blockquote, center, dialog, div, figure, figcaption, footer, form, header, hr, legend, listing,
    \\main, p, plaintext, pre, search, xmp { display: block }
    \\blockquote, figure, listing, p, plaintext, pre, xmp { margin-top: 1em; margin-bottom: 1em }
    \\blockquote, figure { margin-left: 40px; margin-right: 40px }
    \\address { font-style: italic }
    \\listing, plaintext, pre, xmp { font-family: monospace; white-space: pre }
    \\dialog { position: absolute; left: 0; right: 0; width: fit-content; height: fit-content; margin: auto; border: solid; padding: 1em; background-color: Canvas; color: CanvasText }
    \\pre[wrap] { white-space: pre-wrap }
    \\center { text-align: -webkit-center }
    \\cite, dfn, em, i, var { font-style: italic }
    \\b, strong { font-weight: bolder }
    \\code, kbd, samp, tt { font-family: monospace }
    \\big { font-size: larger }
    \\small { font-size: smaller }
    \\sub { vertical-align: sub; font-size: smaller; line-height: normal }
    \\sup { vertical-align: super; font-size: smaller; line-height: normal }
    \\sub, sup { line-height: 1 }
    \\ruby { display: ruby }
    \\rt { font-size: 50% }
    \\u, ins { text-decoration: underline }
    \\s, strike, del { text-decoration: line-through }
    \\abbr[title], acronym[title] { text-decoration: dotted underline }
    \\mark { background-color: Mark; color: MarkText }
    \\q::before { content: open-quote }
    \\q::after { content: close-quote }
    \\br { display-outside: newline }
    \\nobr { white-space: nowrap }
    \\wbr { display-outside: break-opportunity }
    \\nobr wbr { white-space: normal }
    \\[dir=ltr i] { direction: ltr }
    \\[dir=rtl i] { direction: rtl }
    \\bdi, bdo, [dir] { unicode-bidi: isolate }
    \\bdo[dir] { unicode-bidi: isolate-override }
    \\:link, :visited { color: LinkText; text-decoration: underline; cursor: pointer }
    \\:focus-visible { outline: auto }
    \\h1 { margin-top: 0.67em; margin-bottom: 0.67em; font-size: 2.00em; font-weight: bold }
    \\h2 { margin-top: 0.83em; margin-bottom: 0.83em; font-size: 1.50em; font-weight: bold }
    \\h3 { margin-top: 1.00em; margin-bottom: 1.00em; font-size: 1.17em; font-weight: bold }
    \\h4 { margin-top: 1.33em; margin-bottom: 1.33em; font-size: 1.00em; font-weight: bold }
    \\h5 { margin-top: 1.67em; margin-bottom: 1.67em; font-size: 0.83em; font-weight: bold }
    \\h6 { margin-top: 2.33em; margin-bottom: 2.33em; font-size: 0.67em; font-weight: bold }
    \\:is(article, aside, nav, section) h1 { margin-top: 0.83em; margin-bottom: 0.83em; font-size: 1.50em }
    \\:is(article, aside, nav, section) :is(article, aside, nav, section) h1 { margin-top: 1.00em; margin-bottom: 1.00em; font-size: 1.17em }
    \\hgroup > p { margin: 0 }
    \\dir, dd, dl, dt, menu, ol, ul { display: block }
    \\li { display: list-item; text-align: match-parent }
    \\dir, dl, menu, ol, ul { margin-top: 1em; margin-bottom: 1em }
    \\:is(dir, dl, menu, ol, ul) :is(dir, dl, menu, ol, ul) { margin-top: 0; margin-bottom: 0 }
    \\dd { margin-left: 40px }
    \\dir, menu, ol, ul { padding-left: 40px }
    \\ol { list-style-type: decimal }
    \\dir, menu, ul { list-style-type: disc }
    \\:is(dir, menu, ol, ul) :is(dir, menu, ul) { list-style-type: circle }
    \\:is(dir, menu, ol, ul) :is(dir, menu, ol, ul) :is(dir, menu, ul) { list-style-type: square }
    \\ol[type="1"], li[type="1"] { list-style-type: decimal }
    \\ol[type=a s], li[type=a s] { list-style-type: lower-alpha }
    \\ol[type=A s], li[type=A s] { list-style-type: upper-alpha }
    \\ol[type=i s], li[type=i s] { list-style-type: lower-roman }
    \\ol[type=I s], li[type=I s] { list-style-type: upper-roman }
    \\ul[type=none i], li[type=none i] { list-style-type: none }
    \\ul[type=disc i], li[type=disc i] { list-style-type: disc }
    \\ul[type=circle i], li[type=circle i] { list-style-type: circle }
    \\ul[type=square i], li[type=square i] { list-style-type: square }
    \\table { display: table; box-sizing: border-box; border-spacing: 2px; border-collapse: separate; text-indent: initial }
    \\caption { display: table-caption; text-align: center }
    \\colgroup, colgroup[hidden] { display: table-column-group }
    \\col, col[hidden] { display: table-column }
    \\thead, thead[hidden] { display: table-header-group }
    \\tbody, tbody[hidden] { display: table-row-group }
    \\tfoot, tfoot[hidden] { display: table-footer-group }
    \\tr, tr[hidden] { display: table-row }
    \\td, th { display: table-cell }
    \\td, th { padding: 1px }
    \\th { font-weight: bold }
    \\caption { text-align: center }
    \\thead, tbody, tfoot, table > tr { vertical-align: middle }
    \\tr, td, th { vertical-align: inherit }
    \\thead, tbody, tfoot, tr { border-color: inherit }
    \\table[rules=none i], table[rules=groups i], table[rules=rows i], table[rules=cols i], table[rules=all i],
    \\table[frame=void i], table[frame=above i], table[frame=below i], table[frame=hsides i], table[frame=lhs i],
    \\table[frame=rhs i], table[frame=vsides i], table[frame=box i], table[frame=border i],
    \\table[frame=void i] > tr > td, table[rules=all i] > tr > td { border-color: black }
    \\table:not([border]) { border-color: gray }
    \\input, select, button, textarea { letter-spacing: initial; word-spacing: initial; line-height: initial; text-transform: initial; text-indent: initial; text-shadow: initial; appearance: auto }
    \\input, select, textarea { text-align: initial }
    \\input:is([type=reset i], [type=button i], [type=submit i]), button { text-align: center }
    \\input, button { display: inline-block }
    \\input[type=hidden i], input[type=file i], input[type=image i] { appearance: none }
    \\input:is([type=radio i], [type=checkbox i], [type=reset i], [type=button i], [type=submit i], [type=color i], [type=search i]), select, button { box-sizing: border-box }
    \\textarea { white-space: pre-wrap }
    \\input:not([type=image i]), textarea { box-sizing: border-box }
    \\button, input:is([type=reset i], [type=button i], [type=submit i]) { border: 2px outset ButtonBorder; background-color: ButtonFace; color: ButtonText; padding: 1px 6px }
    \\input, textarea, select { border: 2px inset ButtonBorder; background-color: Field; color: FieldText; padding: 1px 2px }
    \\hr { color: gray; border-style: inset; border-width: 1px; margin: 0.5em auto }
    \\fieldset { margin-left: 2px; margin-right: 2px; border: groove 2px ThreeDFace; padding: 0.35em 0.75em 0.625em; min-width: min-content }
    \\legend { padding-left: 2px; padding-right: 2px }
    \\iframe { border: 2px inset }
    \\video { object-fit: contain }
    \\img:is([sizes="auto" i], [sizes^="auto," i]) { contain: size !important; contain-intrinsic-size: 300px 150px }
    \\details > summary:first-of-type { display: list-item; counter-increment: list-item 0; list-style: disclosure-closed inside }
    \\details[open] > summary:first-of-type { list-style-type: disclosure-open }
    \\summary { cursor: default }
    \\marquee { display: inline-block; text-align: initial; overflow: hidden }
    \\meter { appearance: auto }
    \\progress { appearance: auto }
    \\svg:not(:root) { overflow: hidden }
    \\img, svg, video, canvas, audio, iframe, embed, object { overflow: clip }
    \\math { font-family: math }
;

/// Markdown documents' extra user agent styles: readable defaults for
/// what Markdown makes (tables with rules, code on a tint, task lists
/// without bullets), in grays that work on light and dark backgrounds.
pub const markdown_css =
    \\body { line-height: 1.5 }
    \\h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid rgb(128 128 128 / 0.3) }
    \\table { border-collapse: collapse }
    \\th, td { border: 1px solid rgb(128 128 128 / 0.4); padding: 4px 12px }
    \\code { font-family: monospace; font-size: 0.875em; padding: 0.1em 0.3em; border-radius: 4px; background: rgb(128 128 128 / 0.15) }
    \\pre { padding: 12px 16px; border-radius: 6px; background: rgb(128 128 128 / 0.12); white-space: pre-wrap }
    \\pre code { padding: 0; background: none; font-size: 0.875em }
    \\blockquote { margin-left: 0; margin-right: 0; padding: 0 1em; border-left: 0.25em solid rgb(128 128 128 / 0.4); color: color-mix(in srgb, currentcolor 70%, transparent) }
    \\hr { border: 0; height: 0.25em; background: rgb(128 128 128 / 0.25) }
    \\img { max-width: 100% }
    \\.task-list-item { list-style: none }
    \\.task-list-item input { margin: 0 0.4em 0 -1.4em; vertical-align: middle }
;

/// A book's reading defaults, as a user style sheet (D32): a serif face,
/// 1.45 leading, justified text broken with Knuth and Plass, and
/// hyphenation. Author rules (the publisher's CSS) override them.
pub const reading_css =
    \\body { margin: 0; font-family: serif; line-height: 1.45; text-align: justify; hyphens: auto; text-wrap: pretty }
    \\h1, h2, h3, h4, h5, h6 { line-height: 1.2; text-wrap: balance; hyphens: manual }
;

/// Quirks mode's extra user agent styles (HTML, rendering 15.3.6).
pub const quirks_css =
    \\table { font-weight: initial; font-style: initial; font-variant: initial; font-size: initial; line-height: initial; white-space: initial; text-align: initial }
    \\img[align=left i] { margin-right: 3px }
    \\img[align=right i] { margin-left: 3px }
;

/// The toggles of collapsed quoted replies in email.
pub const email_css =
    \\a.siv-quote-toggle { display: inline-block; margin: 0.5em 0; padding: 0 0.5em; border-radius: 0.4em; background: rgb(128 128 128 / 0.2); color: inherit !important; text-decoration: none !important; font-size: 0.85em; line-height: 1.4; letter-spacing: 0.1em }
;
