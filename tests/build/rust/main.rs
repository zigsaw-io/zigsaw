// windows-sys links Windows' functions with raw-dylib, which needs dlltool:
// zig's, through the alias zig's image gives builds.
use windows_sys::Win32::System::SystemInformation::GetTickCount64;

fn main() {
    let name = std::env::args().nth(1).unwrap_or_else(|| "world".into());
    println!("hello, {name}, from Rust");
    println!("Windows is up: {}", unsafe { GetTickCount64() } > 0);
}
