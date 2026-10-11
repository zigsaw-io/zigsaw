# libtool turns -export-symbols(-regex) into a .def with nm, which builds
# don't have. Configured with gl_cv_cc_visibility=no, these libraries mark
# their API __declspec(dllexport), which is what zig's linker exports; it
# ignores --export-all-symbols.
sed -i "/^  -export-symbols-regex '.*' \\\\$/d" gettext-runtime/intl/Makefile
sed -i '/^[[:space:]]*-export-symbols-regex \\$/,+1d' gettext-tools/libgettextpo/Makefile
sed -i 's/-export-symbols libtextstyle.sym //' libtextstyle/lib/Makefile
! grep -q -e '-export-symbols-regex' -e '-export-symbols libtextstyle' gettext-runtime/intl/Makefile gettext-tools/libgettextpo/Makefile libtextstyle/lib/Makefile
# libintl's functions under their plain names (gettext, textdomain, ...),
# which programs that don't include libintl.h call, as Rust's gettext-sys:
# exported for MSVC only, where GNU ld's builds get them from the nm list.
sed -i 's/^#elif defined _MSC_VER && BUILDING_LIBRARY$/#elif defined _WIN32 \&\& BUILDING_LIBRARY/' gettext-runtime/intl/intl-compat.c
grep -q '^#elif defined _WIN32 && BUILDING_LIBRARY$' gettext-runtime/intl/intl-compat.c
# libgettextlib and libgettextsrc mark only their variables dllexport, and
# export the rest with --export-all-symbols. Without any dllexport, the
# linker exports all they define; their users' dllimport finds them as well.
sed -i 's/^\(#   define \(LIBGETTEXTSRC_\)\{0,1\}DLL_VARIABLE\) __declspec (dllexport)$/\1/' gettext-tools/config.h
! grep -q 'DLL_VARIABLE __declspec (dllexport)' gettext-tools/config.h
