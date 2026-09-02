PREFIX ?= /usr/local
BIN = .build/release/sense
# Stable signing identity so macOS TCC grants (mic, speech, camera, screen)
# survive rebuilds. Ad-hoc signatures change every build and trigger a fresh
# permission prompt; fall back to one only if no Developer ID is installed.
SIGN ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')

.PHONY: build sign install uninstall clean test test-vision test-audio release formula
build:
	swift build -c release
	$(MAKE) sign

sign:
ifneq ($(SIGN),)
	codesign --force --sign "$(SIGN)" --identifier com.koszek.sense --options runtime --timestamp=none $(BIN)
else
	@echo "no Developer ID identity found; using ad-hoc signature (permission prompts will repeat after rebuilds)"
	codesign -s - -f --identifier com.koszek.sense $(BIN)
endif

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/sense

uninstall:
	rm -f $(PREFIX)/bin/sense

clean:
	rm -rf .build

test: build test-vision test-audio

test-vision:
	./scripts/smoke-vision.sh $(BIN)

test-audio:
	./scripts/smoke-audio.sh $(BIN)

# Cut a release: bump the version, build universal, sign with the Developer ID,
# notarize, publish to GitHub, print the formula stanza. Refuses to reuse a
# version number — see CLAUDE.md.
#   make release BUMP=patch|minor|major | VERSION=x.y.z | (asks)
#   DRY_RUN=1 make release BUMP=patch    # build+sign+notarize, publish nothing
release: test
	./scripts/release.sh

# Print the current formula stanza (url/sha256) for the published tarball.
formula:
	@v=$$(sed -n 's/.*senseVersion = "\([^"]*\)".*/\1/p' Sources/SenseCore/Version.swift); \
	t=sense-$$v-macos-universal.tar.gz; \
	if [ -f "$$t" ]; then s=$$(shasum -a 256 "$$t" | cut -d' ' -f1); else \
	  s=$$(curl -sfL "https://github.com/wkoszek/sense/releases/download/v$$v/$$t" | shasum -a 256 | cut -d' ' -f1); fi; \
	printf '  url "https://github.com/wkoszek/sense/releases/download/v%s/%s"\n  sha256 "%s"\n  version "%s"\n' "$$v" "$$t" "$$s" "$$v"
