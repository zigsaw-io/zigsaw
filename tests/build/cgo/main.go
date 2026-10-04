// A program for tests/build.sh: built with Go's and zig's SDK images, it
// calls C, in its preamble and in greet.c, which calls Windows.
package main

/*
#include <stdlib.h>
#include "greet.h"

static int twice(int x) { return 2 * x; }
*/
import "C"

import (
	"fmt"
	"os"
	"runtime"
	"unsafe"
)

func main() {
	name := "world"
	if len(os.Args) > 1 {
		name = os.Args[1]
	}
	who := C.CString(name)
	defer C.free(unsafe.Pointer(who))
	greeting := C.greet(who)
	defer C.free(unsafe.Pointer(greeting))
	fmt.Println(C.GoString(greeting))
	fmt.Printf("twice 21 is %d\n", C.twice(21))
	_, file, _, _ := runtime.Caller(0)
	fmt.Printf("built from %s\n", file)
	fmt.Printf("C sees this process: %t\n", int(C.process_id()) == os.Getpid())
}
