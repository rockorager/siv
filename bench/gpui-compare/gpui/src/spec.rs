//! Mirror of common/doc.h: shared constants and content of the scenarios.
//! Keep the two identical.

pub const BENCH_FONT: &str = "Adwaita Sans";
/// siv's body text: 11 pt.
pub const BODY_PX: f32 = 11.0 * 4.0 / 3.0;
pub const DOC_LINE_HEIGHT: f32 = 20.0;
pub const DOC_LARGE_PARAGRAPHS: usize = 4000;
pub const DOC_SMALL_PARAGRAPHS: usize = 6;
/// The word F3 searches for: once, three quarters of the way through the
/// document and the log.
pub const DOC_NEEDLE: &str = "haystackneedle";
/// The log scenario's size.
pub const LOG_BYTES: usize = 100 << 20;

pub const GRID_COLS: usize = 64;
pub const GRID_ROWS: usize = 40;
pub const GRID_PERIOD_MS: u32 = 1000;

pub fn grid_delay_ms(i: usize) -> u32 {
    ((i * 7) % 20) as u32 * 50
}

pub fn grid_color(i: usize) -> u32 {
    const COLORS: [u32; 6] = [0x2563eb, 0xdc2626, 0x16a34a, 0xd97706, 0x9333ea, 0x0891b2];
    COLORS[(i / 3) % 6]
}

const WORDS: [&str; 64] = [
    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "toolkit", "render", "frame", "layout",
    "window", "surface", "glyph", "shaping", "paragraph", "compositor", "latency", "buffer", "pixel", "vector",
    "linear", "light", "scroll", "list", "button", "menu", "editor", "caret", "selection", "input", "method",
    "wayland", "vulkan", "thread", "queue", "present", "damage", "region", "tile", "atlas", "texture", "shader",
    "and", "of", "to", "in", "is", "that", "with", "for", "as", "on", "by", "at", "from", "it", "an", "be",
    "this", "which", "or", "are",
];

fn next(state: &mut u64) -> u32 {
    *state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    (*state >> 33) as u32
}

/// Paragraphs of 20 to 99 words: the same text as doc_generate, one
/// string per paragraph.
pub fn doc_paragraphs(paragraphs: usize) -> Vec<String> {
    let mut state = 12345u64;
    let mut out = Vec::with_capacity(paragraphs);
    for _ in 0..paragraphs {
        let words = 20 + next(&mut state) % 80;
        let mut p = String::new();
        for w in 0..words {
            let word = WORDS[next(&mut state) as usize % WORDS.len()];
            if w > 0 {
                p.push(' ');
                p.push_str(word);
            } else {
                let mut c = word.chars();
                p.extend(c.next().unwrap().to_uppercase());
                p.push_str(c.as_str());
            }
        }
        if out.len() == paragraphs * 3 / 4 {
            p.push(' ');
            p.push_str(DOC_NEEDLE);
        }
        p.push('.');
        out.push(p);
    }
    out
}

const LOG_LEVELS: [&str; 6] = ["INFO ", "INFO ", "INFO ", "DEBUG", "WARN ", "ERROR"];

/// The lines of log_generate, one string per line.
pub fn log_lines() -> Vec<String> {
    let mut state = 777u64;
    let mut out = Vec::new();
    let mut len = 0usize;
    let mut i = 0usize;
    while len < LOG_BYTES {
        if i > 0 {
            len += 1;
        }
        let t = i as u32;
        let ms = next(&mut state) % 1000;
        let worker = next(&mut state) % 16;
        let item = next(&mut state) % 100000;
        let took = next(&mut state) % 500;
        let level = LOG_LEVELS[next(&mut state) as usize % 6];
        let what = WORDS[next(&mut state) as usize % WORDS.len()];
        let mut line = format!(
            "2026-10-13 {:02}:{:02}:{:02}.{:03} {} [worker-{:02}] GET /api/v1/{}/{:05} served in {} ms (request {})",
            t / 3600000 % 24,
            t / 60000 % 60,
            t / 1000 % 60,
            ms,
            level,
            worker,
            what,
            item,
            took,
            i
        );
        len += line.len();
        if len >= LOG_BYTES * 3 / 4 && len - line.len() < LOG_BYTES * 3 / 4 {
            line.push(' ');
            line.push_str(DOC_NEEDLE);
            len += 1 + DOC_NEEDLE.len();
        }
        out.push(line);
        i += 1;
    }
    out
}

/// CSS cubic-bezier(0.42, 0, 0.58, 1), siv's ease-in-out.
pub fn css_ease_in_out(t: f32) -> f32 {
    let (x1, y1, x2, y2) = (0.42f32, 0.0f32, 0.58f32, 1.0f32);
    let bez = |a: f32, b: f32, s: f32| 3.0 * a * s * (1.0 - s) * (1.0 - s) + 3.0 * b * s * s * (1.0 - s) + s * s * s;
    // Solve x(s) = t by bisection; 20 steps is far below a pixel.
    let (mut lo, mut hi) = (0.0f32, 1.0f32);
    for _ in 0..20 {
        let mid = (lo + hi) / 2.0;
        if bez(x1, x2, mid) < t { lo = mid } else { hi = mid }
    }
    bez(y1, y2, (lo + hi) / 2.0)
}
