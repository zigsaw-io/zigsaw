//! Rnote's own fonts on Windows, which has no fontconfig to find them in
//! `share\fonts`, as Linux's has.
//!
//! Pango keeps the fonts added to a font map with that map, and pangocairo's
//! default font map, which piet-cairo lays out text with, is per thread. So
//! each thread that draws text adds them to its own: the main thread, and
//! those of rayon's global pool.

use std::cell::Cell;
use std::ffi::{CString, c_char, c_int, c_void};

unsafe extern "C" {
    fn pango_cairo_font_map_get_default() -> *mut c_void;
    fn pango_font_map_add_font_file(
        fontmap: *mut c_void,
        filename: *const c_char,
        error: *mut *mut c_void,
    ) -> c_int;
}

thread_local! {
    static ADDED: Cell<bool> = const { Cell::new(false) };
}

/// Adds the fonts in `..\share\fonts\rnote-fonts`, from the executable's
/// directory, to this thread's default font map, once.
pub fn add_to_this_thread() {
    if ADDED.with(|added| added.replace(true)) {
        return;
    }
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(prefix) = exe.parent().and_then(|bin| bin.parent()) else {
        return;
    };
    let Ok(entries) = std::fs::read_dir(prefix.join("share").join("fonts").join("rnote-fonts"))
    else {
        return;
    };
    // SAFETY: the default font map lives as long as the thread.
    let fontmap = unsafe { pango_cairo_font_map_get_default() };
    for entry in entries.flatten() {
        let Some(path) = entry.path().to_str().and_then(|p| CString::new(p).ok()) else {
            continue;
        };
        // SAFETY: a valid font map and path; a NULL GError** ignores errors.
        unsafe { pango_font_map_add_font_file(fontmap, path.as_ptr(), std::ptr::null_mut()) };
    }
}

/// Adds them on this thread, and sets up rayon's global pool to add them on
/// its threads.
pub fn setup() {
    add_to_this_thread();
    let _ = rayon::ThreadPoolBuilder::new()
        .start_handler(|_| add_to_this_thread())
        .build_global();
}
