# Orders the modification times of an autotools release tree so that make
# sees its generated files as up to date. Unpacked sources all have the same
# time, as the files in a release tarball often do to the second, and
# BusyBox's make (pdpmake) remakes a target whose prerequisite is as new as
# it, where GNU make doesn't. Its rules would then run aclocal, automake,
# autoconf, autoheader and valac, which builds don't have; and msgfmt,
# makeinfo and help2man for the translations, manuals and man pages a release
# ships built.
find . -type f -exec touch -t 200001010000.00 {} +
find . \( -name aclocal.m4 -o -name '*.stamp' \) -exec touch -t 200001010000.01 {} +
find . \( -name configure -o -name config.h.in -o -name Makefile.in -o -name '*.c' \) -exec touch -t 200001010000.02 {} +
find . \( -name '*.gmo' -o -name stamp-po -o -name stamp-vti -o -name version.texi \) -exec touch -t 200001010000.03 {} +
find . \( -name '*.[13]' -o -name '*.info' -o -name '*.html' \) -exec touch -t 200001010000.04 {} +
