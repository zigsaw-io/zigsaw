#include <stdio.h>
#include <windows.h>
#include <greet.h>

int main(int argc, char **argv) {
    char text[64];
    greet(argc > 1 ? argv[1] : "world");
    /* Where it was built, which should be the same on every machine. */
    printf("built from %s\n", __FILE__);
    printf("twice 21 is %d\n", twice_int(21));
    if (LoadStringA(GetModuleHandleA(NULL), 1, text, sizeof text) > 0) printf("%s\n", text);
    return 0;
}
