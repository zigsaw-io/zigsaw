#include <stdio.h>
#include <greet.h>

int main(int argc, char **argv) {
    greet(argc > 1 ? argv[1] : "world");
    /* Where it was built, which should be the same on every machine. */
    printf("built from %s\n", __FILE__);
    return 0;
}
