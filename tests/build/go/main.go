// A program for tests/build.sh: built with Go's SDK image, it says where it
// was built from (module paths only, with -trimpath), and calls Windows.
package main

import (
	"fmt"
	"os"
	"runtime"
	"syscall"
)

func main() {
	name := "world"
	if len(os.Args) > 1 {
		name = os.Args[1]
	}
	fmt.Printf("hello, %s, from Go\n", name)
	_, file, _, _ := runtime.Caller(0)
	fmt.Printf("built from %s\n", file)
	version, err := syscall.GetVersion()
	fmt.Printf("Windows is up: %t\n", err == nil && version != 0)
}
