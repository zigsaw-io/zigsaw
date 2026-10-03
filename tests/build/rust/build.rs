// The cc crate compiles greet.c with zig's cc, which zig's image gives
// builds as an alias.
fn main() {
    cc::Build::new().file("greet.c").compile("greet");
    println!("cargo:rerun-if-changed=greet.c");
}
