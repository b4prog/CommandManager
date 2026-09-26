PREFIX ?= $(HOME)/.local
SWIFT ?= swift
SWIFT_TEST_FLAGS ?=
SWIFT_FORMAT ?= xcrun swift-format
CODEM8 ?= codem8

.PHONY: build install uninstall test format lint check complexity

build:
	$(SWIFT) build --configuration release --product cm

install: build
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 "$$($(SWIFT) build --configuration release --show-bin-path)/cm" "$(DESTDIR)$(PREFIX)/bin/cm"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/cm"

test:
	$(SWIFT) test --disable-xctest $(SWIFT_TEST_FLAGS)

format:
	$(SWIFT_FORMAT) format --in-place --recursive Sources Package.swift Tests/CommandManagerTests

lint:
	$(SWIFT_FORMAT) lint --strict --recursive Sources Package.swift Tests/CommandManagerTests

check: lint test

complexity:
	$(CODEM8) --report-complexity -git-branch
