// Finds libsiv with pkg-config and generates Rust declarations for siv.h
// with bindgen (which needs libclang). For a checkout of siv, point
// pkg-config at its build: PKG_CONFIG_PATH=../../zig-out/lib/pkgconfig.

fn main() {
    let siv = pkg_config::Config::new()
        .atleast_version("0.1")
        .probe("siv")
        .expect("libsiv not found: run `zig build` and set PKG_CONFIG_PATH to zig-out/lib/pkgconfig");
    // Run in place against an uninstalled libsiv.so.
    for dir in &siv.link_paths {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", dir.display());
    }
    let mut builder = bindgen::Builder::default()
        .header_contents("wrapper.h", "#include <siv.h>")
        .allowlist_function("siv_.*")
        .allowlist_type("siv_.*")
        .allowlist_var("SIV_.*")
        // siv's enums are C enums of fixed values; constants named as in C
        // (SIV_OK, SIV_AXIS_COLUMN) read like the C API and the reference.
        .prepend_enum_name(false)
        .derive_default(true)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()));
    for dir in &siv.include_paths {
        builder = builder.clang_arg(format!("-I{}", dir.display()));
    }
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("siv.rs");
    builder.generate().expect("bindgen failed on siv.h").write_to_file(out).unwrap();
}
