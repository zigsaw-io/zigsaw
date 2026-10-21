# Import libraries that zig's MinGW lacks and Qt links by name:
# synchronization (WaitOnAddress, for QtCore's futex) and runtimeobject
# (WinRT's activation and HSTRING functions). Each is the import library of
# a stub DLL named after the system DLL that has the functions, as
# <name>.lib, which zig's cc finds for -l<name> on the -L path.
#   sh winlibs.sh <dir>
set -e
out=$1
mkdir -p "$out"
cd "$out"
implib() { # implib <lib name> <dll name> <function>...
    lib=$1 dll=$2
    shift 2
    : > stub.c
    for f in "$@"; do printf '__declspec(dllexport) void %s(void) {}\n' "$f" >> stub.c; done
    cc -shared -O2 -s stub.c -o "$dll.dll" "-Wl,--out-implib,$lib.lib"
    rm -f "$dll.dll" stub.c stub.lib
}
implib synchronization api-ms-win-core-synch-l1-2-0 \
    WaitOnAddress WakeByAddressAll WakeByAddressSingle
implib runtimeobject combase \
    RoActivateInstance RoGetActivationFactory RoGetApartmentIdentifier \
    RoInitialize RoRegisterActivationFactories RoRegisterForApartmentShutdown \
    RoRevokeActivationFactories RoUninitialize RoUnregisterForApartmentShutdown \
    WindowsCompareStringOrdinal WindowsConcatString WindowsCreateString \
    WindowsCreateStringReference WindowsDeleteString WindowsDeleteStringBuffer \
    WindowsDuplicateString WindowsGetStringLen WindowsGetStringRawBuffer \
    WindowsInspectString WindowsIsStringEmpty WindowsPreallocateStringBuffer \
    WindowsPromoteStringBuffer WindowsReplaceString \
    WindowsStringHasEmbeddedNull WindowsSubstring \
    WindowsSubstringWithSpecifiedLength WindowsTrimStringEnd \
    WindowsTrimStringStart
