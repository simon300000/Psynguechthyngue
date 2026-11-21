// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const pinnedSyncthingModuleVersion = "v1.30.0-rc.1.0.20260803213605-946e2b83a1f6"

const (
	pinnedGlobReplacement    = "replace github.com/gobwas/glob v0.2.3 => github.com/calmh/glob v0.0.0-20220615080505-1d823af5017b"
	pinnedGatewayReplacement = "replace github.com/jackpal/gateway v1.1.1 => github.com/marbens-arch/gateway v1.1.2-0.20260308173556-c567cc04e7d4"
)

type decodedEnvelope struct {
	SchemaVersion int             `json:"schemaVersion"`
	RequestID     string          `json:"requestID"`
	Kind          string          `json:"kind"`
	OK            bool            `json:"ok"`
	Payload       json.RawMessage `json:"payload"`
	Error         *responseError  `json:"error"`
}

func TestPinnedSyncthingModuleVersion(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("test source location is unavailable")
	}
	goMod, err := os.ReadFile(filepath.Join(filepath.Dir(sourceFile), "..", "go.mod"))
	if err != nil {
		t.Fatal(err)
	}
	contents := string(goMod)
	for _, requiredLine := range []string{
		"github.com/syncthing/syncthing " + pinnedSyncthingModuleVersion,
		pinnedGlobReplacement,
		pinnedGatewayReplacement,
	} {
		if !strings.Contains(contents, requiredLine) {
			t.Fatalf("go.mod is missing exact dependency directive %q", requiredLine)
		}
	}
}

func TestJSONEnvelopes(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })

	snapshot := decodeTestEnvelope(t, mustSnapshot(t, core, `{"schemaVersion":1,"requestID":"snapshot-1"}`))
	if !snapshot.OK || snapshot.Kind != "snapshot" || snapshot.RequestID != "snapshot-1" {
		t.Fatalf("unexpected snapshot envelope: %+v", snapshot)
	}
	var payload snapshotPayload
	if err := json.Unmarshal(snapshot.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Lifecycle != lifecycleCreated || payload.Running {
		t.Fatalf("unexpected initial snapshot: %+v", payload)
	}
	if payload.NetworkPolicy.ManagementHTTPEnabled || payload.NetworkPolicy.UsageReportingEnabled || payload.NetworkPolicy.CrashReportingEnabled || payload.NetworkPolicy.AutoUpgradeEnabled {
		t.Fatalf("embedded network policy is not private: %+v", payload.NetworkPolicy)
	}
	if payload.Identity.PrivateKeyOnDisk {
		t.Fatal("snapshot claims that private key storage is file-backed")
	}

	totals := decodeTestEnvelope(t, core.NetworkTransferTotalsJSON(`{"schemaVersion":1,"requestID":"totals-1"}`))
	if !totals.OK || totals.Kind != "networkTransferTotals" || totals.RequestID != "totals-1" {
		t.Fatalf("unexpected network-transfer envelope: %+v", totals)
	}
	var transferPayload networkTransferTotalsPayload
	if err := json.Unmarshal(totals.Payload, &transferPayload); err != nil {
		t.Fatal(err)
	}
	if transferPayload.ReceivedBytes < 0 || transferPayload.SentBytes < 0 {
		t.Fatalf("network-transfer counters must be nonnegative: %+v", transferPayload)
	}
	if transferPayload.BudgetLimited || transferPayload.BudgetLimitBytes != 0 || transferPayload.BudgetUsedBytes != 0 || transferPayload.BudgetExhausted {
		t.Fatalf("created core inherited a network byte budget: %+v", transferPayload)
	}
	var transferFields map[string]json.RawMessage
	if err := json.Unmarshal(totals.Payload, &transferFields); err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"receivedBytes", "sentBytes", "budgetLimited", "budgetLimitBytes", "budgetUsedBytes", "budgetExhausted"} {
		if _, exists := transferFields[required]; !exists {
			t.Fatalf("network transfer totals omitted required field %q: %s", required, totals.Payload)
		}
	}
	malformedTotals := decodeTestEnvelope(t, core.NetworkTransferTotalsJSON(`{"schemaVersion":1,"requestID":"totals-2","extra":true}`))
	assertEnvelopeErrorCode(t, malformedTotals, "invalid_request")

	ping := decodeTestEnvelope(t, mustCommand(t, core, `{"schemaVersion":1,"requestID":"command-1","command":"ping"}`))
	if !ping.OK || ping.Kind != "command" {
		t.Fatalf("unexpected ping envelope: %+v", ping)
	}

	unsupported := decodeTestEnvelope(t, mustCommand(t, core, `{"schemaVersion":1,"requestID":"command-2","command":"eraseEverything"}`))
	if unsupported.OK || unsupported.Error == nil || unsupported.Error.Code != "unsupported_command" {
		t.Fatalf("unexpected unsupported-command envelope: %+v", unsupported)
	}

	malformed := decodeTestEnvelope(t, mustCommand(t, core, `{`))
	if malformed.OK || malformed.Error == nil || malformed.Error.Code != "invalid_request" {
		t.Fatalf("unexpected malformed-request envelope: %+v", malformed)
	}
}

func TestJSONBoundaryRejectsAmbiguousObjectsBeforeSideEffects(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true

	requests := []struct {
		name string
		run  func() string
	}{
		{
			name: "top-level null",
			run:  func() string { return core.CommandJSON(`null`) },
		},
		{
			name: "duplicate schema",
			run: func() string {
				return core.CommandJSON(`{"schemaVersion":0,"schemaVersion":1,"requestID":"duplicate-schema","command":"start"}`)
			},
		},
		{
			name: "duplicate request ID",
			run: func() string {
				return core.CommandJSON(`{"schemaVersion":1,"requestID":"first","requestID":"second","command":"start"}`)
			},
		},
		{
			name: "duplicate command",
			run: func() string {
				return core.CommandJSON(`{"schemaVersion":1,"requestID":"duplicate-command","command":"ping","command":"start"}`)
			},
		},
		{
			name: "escaped duplicate command",
			run: func() string {
				return core.CommandJSON(`{"schemaVersion":1,"requestID":"escaped-duplicate","command":"ping","\u0063ommand":"start"}`)
			},
		},
		{
			name: "duplicate nested argument",
			run: func() string {
				return core.CommandJSON(`{"schemaVersion":1,"requestID":"duplicate-argument","command":"addDevice","deviceID":"AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA","arguments":{"name":"first","name":"second"}}`)
			},
		},
		{
			name: "duplicate snapshot field",
			run: func() string {
				return core.SnapshotJSON(`{"schemaVersion":1,"requestID":"snapshot-first","requestID":"snapshot-second"}`)
			},
		},
		{
			name: "duplicate query field",
			run: func() string {
				return core.QueryJSON(`{"schemaVersion":1,"requestID":"duplicate-query","query":"items","query":"changes"}`)
			},
		},
		{
			name: "duplicate read field",
			run: func() string {
				return core.ReadRangeJSON(`{"schemaVersion":1,"requestID":"duplicate-read","itemID":"first","itemID":"second","offset":"0","length":"1"}`)
			},
		},
		{
			name: "duplicate totals field",
			run: func() string {
				return core.NetworkTransferTotalsJSON(`{"schemaVersion":1,"requestID":"totals-first","requestID":"totals-second"}`)
			},
		},
		{
			name: "duplicate reconciliation field",
			run: func() string {
				return core.AcknowledgeReconciledCommandJSON(`{"schemaVersion":1,"requestID":"reconcile-first","requestID":"reconcile-second","commandRequestID":"command"}`)
			},
		},
		{
			name: "excessive nesting",
			run: func() string {
				return core.CommandJSON(
					`{"schemaVersion":1,"requestID":"deep","command":"start","extra":` +
						strings.Repeat("[", maxJSONNestingDepth) + `0` +
						strings.Repeat("]", maxJSONNestingDepth) + `}`,
				)
			},
		},
	}

	for _, request := range requests {
		t.Run(request.name, func(t *testing.T) {
			envelope := decodeTestEnvelope(t, request.run())
			assertEnvelopeErrorCode(t, envelope, "invalid_request")
			if envelope.RequestID != "" {
				t.Fatalf("ambiguous request reflected an untrusted request ID: %q", envelope.RequestID)
			}
		})
	}

	core.mu.Lock()
	defer core.mu.Unlock()
	if core.lifecycle != lifecycleCreated || core.runtime != nil {
		t.Fatalf("ambiguous JSON crossed the lifecycle side-effect boundary: lifecycle=%s runtime=%v", core.lifecycle, core.runtime != nil)
	}
	if len(core.commandLedger.entries) != 0 {
		t.Fatalf("ambiguous JSON created durable command entries: %d", len(core.commandLedger.entries))
	}
}

func TestStartStopRestartAndNoPrivateKeyFiles(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true

	identity := core.IdentityBlob()
	deviceID := core.DeviceID()

	startEnvelope := decodeTestEnvelope(t, mustCommand(t, core, `{"schemaVersion":1,"requestID":"start-1","command":"start"}`))
	if !startEnvelope.OK {
		t.Fatalf("start command failed: %+v", startEnvelope.Error)
	}
	assertEmbeddedPolicy(t, core)

	if err := core.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	if got := core.DeviceID(); got != deviceID {
		t.Fatalf("device ID changed after restart: got %q", got)
	}
	stopEnvelope := decodeTestEnvelope(t, mustCommand(t, core, `{"schemaVersion":1,"requestID":"stop-1","command":"stop"}`))
	if !stopEnvelope.OK {
		t.Fatalf("stop command failed: %+v", stopEnvelope.Error)
	}

	for _, name := range []string{"cert.pem", "key.pem", "https-cert.pem", "https-key.pem"} {
		if _, err := os.Stat(filepath.Join(home, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("private identity material unexpectedly exists at %s (stat err %v)", name, err)
		}
	}

	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	reloaded, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	defer reloaded.Close()
	if got := reloaded.DeviceID(); got != deviceID {
		t.Fatalf("device ID changed after constructing a new core: got %q", got)
	}
}

func TestExportedMethodsRejectNilReceiverWithoutPanicking(t *testing.T) {
	var core *Core
	if blob := core.IdentityBlob(); blob != nil {
		t.Fatal("IdentityBlob returned data for a nil receiver")
	}
	if deviceID := core.DeviceID(); deviceID != "" {
		t.Fatal("DeviceID returned a value for a nil receiver")
	}
	if err := core.Start(); err == nil {
		t.Fatal("Start accepted a nil receiver")
	}
	if err := core.Stop(); err == nil {
		t.Fatal("Stop accepted a nil receiver")
	}
	if err := core.Close(); err == nil {
		t.Fatal("Close accepted a nil receiver")
	}
	core.RequestCancel()
	for name, raw := range map[string]string{
		"snapshot":              core.SnapshotJSON(`{"schemaVersion":1,"requestID":"nil"}`),
		"command":               core.CommandJSON(`{"schemaVersion":1,"requestID":"nil","command":"ping"}`),
		"query":                 core.QueryJSON(`{"schemaVersion":1,"requestID":"nil","query":"items"}`),
		"networkTransferTotals": core.NetworkTransferTotalsJSON(`{"schemaVersion":1,"requestID":"nil"}`),
	} {
		envelope := decodeTestEnvelope(t, raw)
		assertEnvelopeErrorCode(t, envelope, "core_unavailable")
		if envelope.Kind != name || envelope.RequestID != "nil" {
			t.Fatalf("%s nil envelope lost identity: %+v", name, envelope)
		}
	}
	readEnvelope := decodeTestEnvelope(t, core.ReadRangeJSON(`{"schemaVersion":1,"requestID":"nil"}`))
	assertEnvelopeErrorCode(t, readEnvelope, "core_unavailable")
	if readEnvelope.Kind != "readRange" || readEnvelope.RequestID != "nil" {
		t.Fatalf("ReadRangeJSON nil envelope lost identity: %+v", readEnvelope)
	}
	acknowledgement := decodeTestEnvelope(t, core.AcknowledgeCommand("nil"))
	assertEnvelopeErrorCode(t, acknowledgement, "core_unavailable")
	if acknowledgement.Kind != commandAcknowledgementKind || acknowledgement.RequestID != "nil" {
		t.Fatalf("AcknowledgeCommand nil envelope lost identity: %+v", acknowledgement)
	}
}

func TestRecoveredPanicDoesNotExposePanicValue(t *testing.T) {
	var recovered error
	func() {
		defer recoverAsError(&recovered)
		panic("private material")
	}()
	if !errors.Is(recovered, errInternalPanic) {
		t.Fatalf("panic was not converted to the stable error: %v", recovered)
	}
	if recovered.Error() != errInternalPanic.Error() {
		t.Fatalf("panic details leaked into error: %q", recovered)
	}
}

func assertEmbeddedPolicy(t *testing.T, core *Core) {
	t.Helper()
	core.mu.Lock()
	defer core.mu.Unlock()
	if core.runtime == nil || core.runtime.configuration == nil {
		t.Fatal("runtime configuration is unavailable")
	}
	configuration := core.runtime.configuration.RawCopy()
	if configuration.GUI.Enabled {
		t.Fatal("management GUI is enabled")
	}
	options := configuration.Options
	if options.StartBrowser || options.URAccepted != 0 || options.URUniqueID != "" || options.URPostInsecurely || options.CREnabled || options.AutoUpgradeIntervalH != 0 || options.UpgradeToPreReleases {
		t.Fatalf("embedded privacy policy was not enforced: %+v", options)
	}
}

func mustSnapshot(t *testing.T, core *Core, request string) string {
	t.Helper()
	return core.SnapshotJSON(request)
}

func mustCommand(t *testing.T, core *Core, request string) string {
	t.Helper()
	return core.CommandJSON(request)
}

func decodeTestEnvelope(t *testing.T, raw string) decodedEnvelope {
	t.Helper()
	var envelope decodedEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("decode envelope %q: %v", raw, err)
	}
	if envelope.SchemaVersion != envelopeSchemaVersion {
		t.Fatalf("unexpected envelope schema: %d", envelope.SchemaVersion)
	}
	return envelope
}
