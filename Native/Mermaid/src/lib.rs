use merman::render::HeadlessRenderer;
use resvg::{tiny_skia, usvg};
use std::{panic::{catch_unwind, AssertUnwindSafe}, sync::{Arc, OnceLock}};

fn render(source: &str, scale: f32) -> Result<Vec<u8>, String> {
    if source.len() > 32_768 || source.lines().count() > 256 || source.matches(';').count() > 512 {
        return Err("Diagram exceeds the 32 KB / 256 line / 512 statement limit".into());
    }
    if !scale.is_finite() || !(1.0..=3.0).contains(&scale) { return Err("Invalid scale".into()); }
    let svg = HeadlessRenderer::new().render_svg_resvg_safe_sync(source)
        .map_err(|e| e.to_string())?.ok_or("No Mermaid diagram found")?;
    if svg.len() > 8_000_000 { return Err("Diagram SVG is too large".into()); }
    static FONTS: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    let fonts = FONTS.get_or_init(|| {
        let mut db = usvg::fontdb::Database::new();
        db.load_system_fonts();
        db.set_sans_serif_family("Helvetica");
        Arc::new(db)
    });
    let options = usvg::Options {
        fontdb: fonts.clone(), font_family: "Helvetica".into(),
        // Diagrams cannot read files, URLs or embedded image payloads.
        image_href_resolver: usvg::ImageHrefResolver {
            resolve_string: Box::new(|_, _| None), resolve_data: Box::new(|_, _, _| None),
        },
        ..Default::default()
    };
    let tree = usvg::Tree::from_str(&svg, &options).map_err(|e| e.to_string())?;
    let size = tree.size();
    let factor = scale.min(4096.0 / size.width().max(size.height()))
        .min((8_000_000.0 / (size.width() * size.height())).sqrt());
    let width = (size.width() * factor).ceil().max(1.0) as u32;
    let height = (size.height() * factor).ceil().max(1.0) as u32;
    let mut pixmap = tiny_skia::Pixmap::new(width, height).ok_or("Cannot allocate diagram")?;
    resvg::render(&tree, tiny_skia::Transform::from_scale(factor, factor), &mut pixmap.as_mut());
    pixmap.encode_png().map_err(|e| e.to_string())
}

/// Returns PNG bytes on success (0), UTF-8 diagnostic on error (1), or invalid arguments (2).
/// The caller owns the buffer and must release it exactly once with hanshi_mermaid_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hanshi_mermaid_render(source: *const u8, length: usize, scale: f32,
    output: *mut *mut u8, output_length: *mut usize) -> i32 {
    if source.is_null() || output.is_null() || output_length.is_null() { return 2; }
    unsafe { *output = std::ptr::null_mut(); *output_length = 0; }
    let result = catch_unwind(AssertUnwindSafe(|| {
        if length > 32_768 { return Err("Diagram exceeds 32 KB".into()); }
        let source = unsafe { std::slice::from_raw_parts(source, length) };
        render(std::str::from_utf8(source).map_err(|e| e.to_string())?, scale)
    })).unwrap_or_else(|_| Err("Mermaid renderer failed".into()));
    let (status, bytes) = match result { Ok(bytes) => (0, bytes), Err(error) => (1, error.into_bytes()) };
    let mut bytes = bytes.into_boxed_slice();
    unsafe { *output_length = bytes.len(); *output = bytes.as_mut_ptr(); }
    std::mem::forget(bytes);
    status
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hanshi_mermaid_free(bytes: *mut u8, length: usize) {
    if !bytes.is_null() { unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, length))); } }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn diagrams_and_errors() {
        for source in ["flowchart TD\nA[Start] --> B[Done]", "sequenceDiagram\nAlice->>Bob: Hello",
            "gantt\n title Work\n dateFormat YYYY-MM-DD\n section Build\n Task :2026-01-01, 2d",
            "mindmap\n root((Notes))\n  Ideas\n  Tasks", "pie\n \"A\": 3\n \"B\": 2"] {
            let png = render(source, 2.0).unwrap();
            assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
            assert!(png.len() > 100);
        }
        assert!(render("not a diagram", 2.0).is_err());
        assert!(render(&"x".repeat(32_769), 2.0).is_err());
        assert!(render("flowchart TD\nA-->B", f32::NAN).is_err());
    }
    #[test] fn abi_ownership_and_invalid_utf8() {
        let mut ptr = std::ptr::null_mut(); let mut length = 0;
        unsafe {
            assert_eq!(hanshi_mermaid_render([255u8].as_ptr(), 1, 2.0, &mut ptr, &mut length), 1);
            assert!(!ptr.is_null()); assert!(length > 0); hanshi_mermaid_free(ptr, length);
            assert_eq!(hanshi_mermaid_render(std::ptr::null(), 0, 2.0, &mut ptr, &mut length), 2);
        }
    }
}
