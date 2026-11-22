// SPDX-License-Identifier: MIT

package psybridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIgnoreMatcherUpstreamSemantics(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "inc"), []byte("*.psd\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := NewIgnoreMatcher(root, "*.skip\n/build\n(?i)Cache\n#include inc\n!keep.tmp\n*.tmp\n")
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]bool{
		"a.skip": true, "d/e/a.skip": true, // unanchored: any depth
		"build": true, "build/x.o": true, "d/build/x.o": false, // anchored dir covers contents
		"cache/x": true, "CACHE": true, // case-insensitive
		"art.psd": true,           // via #include
		"keep.tmp": false, "x.tmp": true, // first match wins
		"报告/a b.txt": false,
	}
	for p, want := range cases {
		if got := m.Match(p); got != want {
			t.Errorf("Match(%q) = %v, want %v", p, got, want)
		}
	}
	if _, err := NewIgnoreMatcher(root, "#include missing\n"); err == nil {
		t.Error("missing include must fail like upstream")
	}
}
