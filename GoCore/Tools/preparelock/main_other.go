// SPDX-License-Identifier: MIT
//go:build !darwin && !linux

package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "preparelock: kernel file locking is supported only on Darwin and Linux")
	os.Exit(1)
}
