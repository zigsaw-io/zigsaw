# Edits to qtbase 6.12.0's sources for building with zig, each checked:
set -e

# qthread_win.cpp uses QSpan without including it; MSVC's headers bring it
# in, libc++'s don't.
sed -i 's|^#include "qmutex.h"$|&\n#include "qspan.h"|' src/corelib/thread/qthread_win.cpp
grep -q '^#include "qspan.h"$' src/corelib/thread/qthread_win.cpp

# QtCore links runtimeobject privately and publicly; the public one would
# make every app link it too, and only winlibs.sh's copy has it. QtCore
# itself still links it.
sed -i '/PUBLIC_LIBRARIES/,/^)/{/^        runtimeobject$/d}' src/corelib/CMakeLists.txt
test "$(grep -c '^        runtimeobject$' src/corelib/CMakeLists.txt)" = 1

# The .rc that embeds an executable's manifest names the manifest file
# unquoted; zig's rc (like Microsoft's) reads lrelease-pro_internal_qt.manifest
# as "lrelease" and an expression. Quoted, a name with a "-" works.
sed -i 's|/\* RT_MANIFEST \*/ ${target_mn_filename}")$|/* RT_MANIFEST */ \\"${target_mn_filename}\\"")|' src/corelib/Qt6CoreMacros.cmake
grep -qF '/* RT_MANIFEST */ \"${target_mn_filename}\"")' src/corelib/Qt6CoreMacros.cmake

# CMake makes a WIN32_EXECUTABLE a GUI program with -mwindows, which zig's
# cc ignores: Designer, and every app's window, would come with a console.
# QtCore asks executables that link it for the linker's flag instead.
cat >> src/corelib/CMakeLists.txt <<'CMAKE'

if(MINGW)
    target_link_options(Core INTERFACE
        "$<$<AND:$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>,$<BOOL:$<TARGET_PROPERTY:WIN32_EXECUTABLE>>>:-Wl,--subsystem,windows>")
endif()
CMAKE
grep -q -- '-Wl,--subsystem,windows>")$' src/corelib/CMakeLists.txt

# QLocalServer can't listen in an AppContainer, which may create named pipes
# only in its own namespace: an app's single-instance check (Flameshot's
# KDSingleApplication) failed, and the app quit. In one, servers and sockets
# use that namespace.
patch -p1 < zigsaw/qlocalserver-appcontainer.patch
