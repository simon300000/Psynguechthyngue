module github.com/simon300000/Psynguechthyngue/GoBridge

go 1.25.0

// WP-A will add:
//   require github.com/syncthing/syncthing <pseudo-version of the pinned official release commit>
//   plus the two `replace` lines copied verbatim from upstream's go.mod
//   (github.com/gobwas/glob, github.com/jackpal/gateway).
// No local replace of syncthing and no patches are allowed (see Docs/REWRITE/DESIGN.md §3).
