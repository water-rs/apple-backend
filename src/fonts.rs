//! Bundled font registration.
//!
//! The CLI stages the fonts `Water.toml` declares into the app bundle's
//! `fonts/` resource directory. Every font file there registers into the
//! process's font tables before the app body runs, so text that names the
//! family resolves on the first frame rather than after a lazy lookup.

/// Registers every font file in the bundle's `fonts/` directory.
///
/// A missing directory is not an error — most apps declare no bundled fonts.
pub fn register_bundle_fonts(resources: &waterui_core::ResourceContext) {
    let entries = match std::fs::read_dir(resources.fonts()) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
        Err(error) => panic!(
            "cannot read font directory {}: {error}",
            resources.fonts().display()
        ),
    };
    for entry in entries {
        let path = entry.expect("font directory entry must be readable").path();
        // The CLI also stages its family-to-file JSON manifest here.
        if path
            .file_name()
            .is_some_and(|name| name == "waterui-fonts.json")
        {
            continue;
        }
        let metadata = std::fs::metadata(&path).unwrap_or_else(|error| {
            panic!(
                "cannot read bundled font metadata {}: {error}",
                path.display()
            )
        });
        if !metadata.is_file() {
            continue;
        }
        cocoa_ui::fonts::register_font(&path).unwrap_or_else(|error| {
            panic!(
                "failed to register bundled font {}: {error}",
                path.display()
            )
        });
    }
}
