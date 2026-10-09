# $LD for libtool: lld's MinGW driver, from zig, which takes GNU ld's
# options. libtool makes DLLs the GNU way only if `$LD --help` mentions
# auto-import, which lld supports but its help doesn't say. libtool links
# with $CC anyway; this answers its checks, and its rare direct uses (-r).
case "$1" in
--help) zig ld.lld -m i386pep --help; echo '  --enable-auto-import' ;;
*) exec zig ld.lld -m i386pep "$@" ;;
esac
