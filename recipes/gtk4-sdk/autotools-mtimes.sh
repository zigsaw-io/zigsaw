# Orders the modification times of an autotools release tree so that make
# sees its generated files as up to date. Unpacked sources all have the same
# time, as the files in a release tarball often do to the second, and
# BusyBox's make (pdpmake) remakes a target whose prerequisite is as new as
# it, where GNU make doesn't. Its rules would then run aclocal, automake,
# autoconf, autoheader and valac, which builds don't have.
find . -type f -exec touch -t 200001010000.00 {} +
find . \( -name aclocal.m4 -o -name '*.stamp' \) -exec touch -t 200001010000.01 {} +
find . \( -name configure -o -name config.h.in -o -name Makefile.in -o -name '*.c' \) -exec touch -t 200001010000.02 {} +
