// SPDX-License-Identifier: MIT

package psybridge

import (
	"strings"

	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/ignore"
)

// IgnoreMatcher evaluates ignore lines with upstream's own semantics
// (lib/ignore: anchoring, **, (?i), directory patterns cover their
// contents, first match wins, #include relative to the folder root).
// Swift uses it for the user's own rules only — not the on-demand `*`
// rule — to keep paths the user excluded out of the Files list.
type IgnoreMatcher struct {
	m *ignore.Matcher
}

// NewIgnoreMatcher parses newline-separated lines as a .stignore located
// at folderRoot.
func NewIgnoreMatcher(folderRoot string, lines string) (*IgnoreMatcher, error) {
	filesystem := fs.NewFilesystem(fs.FilesystemTypeBasic, folderRoot)
	m := ignore.New(filesystem)
	if err := m.Parse(strings.NewReader(lines), ".stignore"); err != nil {
		return nil, err
	}
	return &IgnoreMatcher{m: m}, nil
}

// Match reports whether the folder-relative path is ignored.
func (i *IgnoreMatcher) Match(path string) bool {
	return i.m.Match(path).IsIgnored()
}
