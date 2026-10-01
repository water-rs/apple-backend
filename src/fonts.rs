//! Bundled font registration.
//!
//! The CLI stages the fonts `Water.toml` declares into the app bundle's
//! `fonts/` resource directory. Every font file there registers into the
//! process's font tables before the app body runs, so text that names the
//! family resolves on the first frame rather than after a lazy lookup.

/// Registers every font file in the bundle's `fonts/` directory.
///
/// A missing directory is not an error — most apps declare no bundled fonts.
pub fn register_bundle_fonts() {
    let Some(resources) = cocoa_ui::bundle::resource_directory() else {
        return;
    };
    let fonts_dir = resources.join("fonts");
    let Ok(entries) = std::fs::read_dir(&fonts_dir) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        if let Err(error) = cocoa_ui::fonts::register_font(&path) {
            tracing::warn!(
                "failed to register bundled font {}: {error}",
                path.display()
            );
        }
    }
}
