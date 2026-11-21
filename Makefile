.PHONY: bootstrap bootstrap-policy-test verify sanity format-check swift-test scale-test go-verify peer-interop peer-scale-test peer-scale-100k-test ios-build ui-test physical-files-ui-test licenses license-test sbom notices source-bundle release-licenses verify-app-store-export

SOURCE_VERSION ?= unpublished
SOURCE_BUNDLE ?= .build/release/Psynguechthyngue-$(SOURCE_VERSION)-release-sources.tar.gz
SOURCE_OFFER ?=
APP_STORE_ARCHIVE ?=
APP_STORE_IPA ?=

bootstrap:
	bash Scripts/bootstrap.sh

bootstrap-policy-test:
	bash Scripts/test-bootstrap-no-reuse.sh

verify:
	bash Scripts/verify.sh

sanity:
	bash Scripts/verify.sh sanity

format-check:
	bash Scripts/verify.sh format

swift-test:
	bash Scripts/verify.sh swift

scale-test:
	bash Scripts/test-scale.sh

go-verify:
	bash Scripts/verify.sh go

peer-interop:
	bash Scripts/verify.sh interop

peer-scale-test:
	PEER_INTEROP_SMALL_FILE_COUNT=10000 bash Scripts/verify.sh interop

peer-scale-100k-test:
	PEER_INTEROP_SMALL_FILE_COUNT=100000 bash Scripts/verify.sh interop

ios-build:
	bash Scripts/verify.sh ios

ui-test:
	bash Scripts/verify.sh ui

physical-files-ui-test:
	bash Scripts/test-physical-files-ui.sh

licenses:
	bash Scripts/check-licenses.sh

license-test:
	bash Scripts/test-license-tools.sh

sbom:
	bash Scripts/generate-sbom.sh

notices:
	bash Scripts/generate-third-party-notices.sh

source-bundle:
	bash Scripts/prepare-release-source.sh "$(SOURCE_VERSION)" "$(SOURCE_BUNDLE)"

release-licenses:
	bash Scripts/verify-release-licenses.sh "$(SOURCE_OFFER)"

verify-app-store-export:
	@test -n "$(APP_STORE_ARCHIVE)" || { echo "APP_STORE_ARCHIVE is required" >&2; exit 64; }
	@test -n "$(APP_STORE_IPA)" || { echo "APP_STORE_IPA is required" >&2; exit 64; }
	bash Scripts/verify-app-store-export.sh --archive "$(APP_STORE_ARCHIVE)" --ipa "$(APP_STORE_IPA)"
