PREFIX ?= $(HOME)/.local
SWIFT ?= swift
SWIFT_TEST_FLAGS ?=
SWIFT_FORMAT ?= xcrun swift-format
CODEM8 ?= codem8

.PHONY: install uninstall test format lint check complexity

install:
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 cm.swift "$(DESTDIR)$(PREFIX)/bin/cm"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/cm"

test:
	$(SWIFT) test --disable-xctest $(SWIFT_TEST_FLAGS)

format:
	$(SWIFT_FORMAT) format --in-place --recursive cm.swift Package.swift Tests/CommandManagerTests

lint:
	$(SWIFT_FORMAT) lint --strict --recursive cm.swift Package.swift Tests/CommandManagerTests

check: lint test

complexity:
	$(CODEM8) --report-complexity -git-branch
