.PHONY: bootstrap project verify sanity format-check swift-test go-test ios-build ui-test licenses sbom notices verify-app-store-export e2e-local

APP_STORE_ARCHIVE ?=
APP_STORE_IPA ?=

# Artifacts/PsyBridge.xcframework (rebuilt only when GoBridge inputs change).
bootstrap:
	bash Scripts/bootstrap.sh

# Regenerate Psynguechthyngue.xcodeproj (deterministic).
project:
	ruby Scripts/generate-xcodeproj.rb

# Full gate: sanity, swift test, GoBridge tests (noassets), licenses,
# iOS Simulator + device builds, Simulator UI tests.
verify:
	bash Scripts/verify.sh

sanity:
	bash Scripts/verify.sh sanity

format-check:
	bash Scripts/verify.sh format

swift-test:
	bash Scripts/verify.sh swift

go-test:
	bash Scripts/verify.sh go

ios-build:
	bash Scripts/verify.sh ios

ui-test:
	bash Scripts/verify.sh ui

licenses:
	bash Scripts/check-licenses.sh

sbom:
	bash Scripts/generate-sbom.sh

notices:
	bash Scripts/generate-third-party-notices.sh

verify-app-store-export:
	@test -n "$(APP_STORE_ARCHIVE)" || { echo "APP_STORE_ARCHIVE is required" >&2; exit 64; }
	@test -n "$(APP_STORE_IPA)" || { echo "APP_STORE_IPA is required" >&2; exit 64; }
	bash Scripts/verify-app-store-export.sh --archive "$(APP_STORE_ARCHIVE)" --ipa "$(APP_STORE_IPA)"

# E2E against the official Syncthing on this Mac.
e2e-local:
	bash Scripts/e2e-local-syncthing.sh
