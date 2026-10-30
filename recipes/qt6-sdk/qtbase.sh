# Edits to qtbase 6.12.0's sources, each checked:
set -e

# qthread_win.cpp uses QSpan without including it; MSVC's headers bring it
# in, libc++'s don't.
sed -i 's|^#include "qmutex.h"$|&\n#include "qspan.h"|' src/corelib/thread/qthread_win.cpp
grep -q '^#include "qspan.h"$' src/corelib/thread/qthread_win.cpp

# The .rc that embeds an executable's manifest names the manifest file
# unquoted; zig's rc (like Microsoft's) read lrelease-pro_internal_qt.manifest
# as "lrelease" and an expression. llvm-windres reads it either way; quoted,
# every rc does.
sed -i 's|/\* RT_MANIFEST \*/ ${target_mn_filename}")$|/* RT_MANIFEST */ \\"${target_mn_filename}\\"")|' src/corelib/Qt6CoreMacros.cmake
grep -qF '/* RT_MANIFEST */ \"${target_mn_filename}\"")' src/corelib/Qt6CoreMacros.cmake

# QLocalServer can't listen in an AppContainer, which may create named pipes
# only in its own namespace: an app's single-instance check (Flameshot's
# KDSingleApplication) failed, and the app quit. In one, servers and sockets
# use that namespace.
patch -p1 < zigsaw/qlocalserver-appcontainer.patch
