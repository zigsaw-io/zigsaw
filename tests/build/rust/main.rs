// windows-sys links Windows' functions with raw-dylib, which needs dlltool:
// zig's, through the alias zig's image gives builds. greet_c is C, which
// build.rs compiles with zig's cc.
use windows_sys::Win32::System::SystemInformation::GetTickCount64;

unsafe extern "C" {
    fn greet_c(buf: *mut u8, len: usize, name: *const std::ffi::c_char) -> i32;
}

fn main() {
    let name = std::env::args().nth(1).unwrap_or_else(|| "world".into());
    println!("hello, {name}, from Rust");
    let c_name = std::ffi::CString::new(name).unwrap();
    let mut buf = [0u8; 128];
    let n = unsafe { greet_c(buf.as_mut_ptr(), buf.len(), c_name.as_ptr()) };
    println!("{}", String::from_utf8_lossy(&buf[..n as usize]));
    println!("Windows is up: {}", unsafe { GetTickCount64() } > 0);
}
