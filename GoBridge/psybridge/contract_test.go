// SPDX-License-Identifier: MIT

package psybridge

import "testing"

func TestErrorCodeRoundTrip(t *testing.T) {
	err := newError(CodeNoPeer, "no device for %s", "f1")
	if got := ErrorCode(err.Error()); got != CodeNoPeer {
		t.Fatalf("ErrorCode = %q", got)
	}
	if got := ErrorCode("psy:" + CodeCancelled); got != CodeCancelled {
		t.Fatalf("ErrorCode bare = %q", got)
	}
	if got := ErrorCode("boom"); got != "" {
		t.Fatalf("ErrorCode foreign = %q", got)
	}
}

func TestStubsReportNotImplemented(t *testing.T) {
	e, err := NewEngine(&EngineConfig{HomeDir: t.TempDir(), CertPEM: []byte("c"), KeyPEM: []byte("k")}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.Start(1); codeOf(err) != CodeNotImplemented {
		t.Fatalf("Start: %v", err)
	}
	if _, err := FetchFile(&FetchRequest{FolderID: "f", Path: "p", DestinationPath: "/tmp/x"}, nil); codeOf(err) != CodeNotImplemented {
		t.Fatalf("FetchFile: %v", err)
	}
	if _, err := FetchFile(&FetchRequest{}, nil); codeOf(err) != CodeInvalidArgument {
		t.Fatalf("FetchFile invalid: %v", err)
	}
}

func TestAPIVersion(t *testing.T) {
	if APIVersion() != 2 {
		t.Fatal("bridge API version must be 2")
	}
}
