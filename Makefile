PREFIX ?= /usr/local
BIN = .build/release/sense
# Stable signing identity so macOS TCC grants (mic, speech, camera, screen)
# survive rebuilds. Ad-hoc signatures change every build and trigger a fresh
# permission prompt; fall back to one only if no Developer ID is installed.
SIGN ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')

.PHONY: build sign install uninstall clean test test-vision test-audio
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
