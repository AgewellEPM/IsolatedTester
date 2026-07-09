.PHONY: build release sign install test clean

BINARY_NAME = isolated
MCP_BINARY = isolated-mcp
HTTP_BINARY = isolated-http
BUILD_DIR = .build/release
INSTALL_DIR = /usr/local/bin
IDENTITY ?= -

build:
	swift build

release:
	swift build -c release

sign: release
	codesign --force --sign "$(IDENTITY)" \
		--entitlements IsolatedTester.entitlements \
		--options runtime \
		$(BUILD_DIR)/$(BINARY_NAME)
	@if [ -f $(BUILD_DIR)/$(MCP_BINARY) ]; then \
		codesign --force --sign "$(IDENTITY)" \
			--entitlements IsolatedTester.entitlements \
			--options runtime \
			$(BUILD_DIR)/$(MCP_BINARY); \
	fi
	@if [ -f $(BUILD_DIR)/$(HTTP_BINARY) ]; then \
		codesign --force --sign "$(IDENTITY)" \
			--entitlements IsolatedTester.entitlements \
			--options runtime \
			$(BUILD_DIR)/$(HTTP_BINARY); \
	fi

install: sign
	install -d $(INSTALL_DIR)
	install $(BUILD_DIR)/$(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)
	@if [ -f $(BUILD_DIR)/$(MCP_BINARY) ]; then \
		install $(BUILD_DIR)/$(MCP_BINARY) $(INSTALL_DIR)/$(MCP_BINARY); \
	fi
	@if [ -f $(BUILD_DIR)/$(HTTP_BINARY) ]; then \
		install $(BUILD_DIR)/$(HTTP_BINARY) $(INSTALL_DIR)/$(HTTP_BINARY); \
	fi

test:
	swift test

clean:
	swift package clean
	rm -rf reports/ screenshots/

lint:
	swiftlint lint --strict 2>/dev/null || echo "SwiftLint not installed, skipping"
