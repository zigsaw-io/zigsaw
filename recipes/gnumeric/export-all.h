/* Force-included into goffice's and Gnumeric's builds (-include). Their
 * plugins are DLLs that GModule looks up symbols in by name, and link with
 * -Wl,--export-all-symbols, as some of those symbols (math_functions[]) carry
 * no G_MODULE_EXPORT. zig's linker takes the option but doesn't act on it:
 * a DLL exports only what is marked __declspec(dllexport), and everything
 * (as GNU ld's does) only when nothing is. So G_MODULE_EXPORT marks nothing
 * here. The libraries export what their .def files list either way. */
#include <gmodule.h>
#undef G_MODULE_EXPORT
#define G_MODULE_EXPORT
