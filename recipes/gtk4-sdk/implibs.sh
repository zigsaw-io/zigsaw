# zig's cc looks for -lfoo as foo.dll, foo.lib or libfoo.a, but not as
# libfoo.dll.a, the name MinGW import libraries have. Meson links them by
# path; libtool and `cc $(pkg-config --libs gtk4)` need them by name. Copies
# each lib*.dll.a in $1 to <name>.lib next to it.
for f in "$1"/lib*.dll.a; do
  [ -f "$f" ] || continue
  b=${f##*/lib}
  cp "$f" "$1/${b%.dll.a}.lib"
done
