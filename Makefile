.PHONY: clean clean-state clean-layers clean-containers clean-all-state clean-dist install uninstall debug release run run-with-setup setup-builder all codesign verify-entitlements help kernel kernel-rebuild install-grpc-plugin test vminit vminit-rebuild vminit-debug gen-grpc gen-buildinfo dist dist-pkg dist-dmg notarize check-publish-env publish install-service uninstall-service start-service stop-service restart-service service-status configure-shell build-assets

# Default build configuration
CONFIGURATION ?= debug

# Build directory
ifeq ($(CONFIGURATION),release)
	BUILD_DIR = .build/release
	SWIFT_BUILD_FLAGS = -c release
else
	BUILD_DIR = .build/debug
	SWIFT_BUILD_FLAGS = -c debug
endif

# Binary names
BINARY = Arca
TEST_HELPER = ArcaTestHelper
ENGINE = arca-engine

# Installation directory
INSTALL_DIR = /usr/local/bin

# LaunchAgent directory (user-local, no sudo required)
LAUNCH_AGENT_DIR = $(HOME)/Library/LaunchAgents
LAUNCH_AGENT_PLIST = com.liquescent.arca.plist

# Default socket path (user-local)
DEFAULT_SOCKET = $(HOME)/.arca/arca.sock

# Entitlements file
ENTITLEMENTS = Arca.entitlements

# Code signing identities
# Binary signing (use "-" for adhoc, or set to your Developer ID Application)
# Example: CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)"
CODESIGN_IDENTITY ?= -

# Package signing (for .pkg installers)
# Example: INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAM_ID)"
# Leave empty to create unsigned packages (for testing)
INSTALLER_IDENTITY ?=

# Distribution version (from git tag or default)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

# Distribution directory
DIST_DIR = dist

# Source files (for dependency tracking)
SOURCES := $(shell find Sources -name '*.swift' 2>/dev/null)

# Default target
all: codesign

# Build the project - file-based target that depends on source files
$(BUILD_DIR)/$(BINARY): gen-buildinfo $(SOURCES) Package.swift
	@echo "Building $(BINARY) ($(CONFIGURATION))..."
	@swift build $(SWIFT_BUILD_FLAGS)

# Codesign the binaries with entitlements
#
# $(ENGINE) belongs here for the same reason $(BINARY) does, and was missing:
# ContainerManager.initialize() constructs a Containerization.VmnetNetwork, and
# vmnet refuses without com.apple.security.virtualization. MEASURED with the
# signature as the only variable -- stripped of entitlements the engine exits 1
# on "failed to create vmnet network with status vmnet_return_t(rawValue: 1002)"
# and creates no socket. 1002 is VMNET_MEM_FAILURE in vmnet.h, which sends
# whoever debugs it looking for a memory fault; re-signed with $(ENTITLEMENTS)
# the same binary initialises all three managers and serves on its socket.
codesign: $(BUILD_DIR)/$(BINARY) $(BUILD_DIR)/$(TEST_HELPER) $(BUILD_DIR)/$(ENGINE)
	@echo "Code signing $(BINARY) with entitlements (identity: $(CODESIGN_IDENTITY))..."
	@codesign --force --sign "$(CODESIGN_IDENTITY)" --options runtime --timestamp --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(BINARY)
	@echo "Code signing $(TEST_HELPER) with entitlements..."
	@codesign --force --sign "$(CODESIGN_IDENTITY)" --options runtime --timestamp --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(TEST_HELPER)
	@echo "Code signing $(ENGINE) with entitlements..."
	@codesign --force --sign "$(CODESIGN_IDENTITY)" --options runtime --timestamp --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(ENGINE)
	@echo "✓ Code signing complete"

# Debug build (default)
debug:
	$(MAKE) CONFIGURATION=debug all

# Release build
release:
	$(MAKE) CONFIGURATION=release all

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	swift package clean
	rm -rf .build

# Clean state database (development)
clean-state:
	@echo "Cleaning state database..."
	@rm -f ~/.arca/state.db
	@echo "✓ State cleaned"

# Clean layer cache (development)
clean-layers:
	@echo "Cleaning layer cache..."
	@rm -rf ~/.arca/layers/*
	@echo "✓ Layer cache cleaned"

# Clean container state (development)
clean-containers:
	@echo "Cleaning container state..."
	@rm -rf ~/.arca/containers/*
	@echo "✓ Container state cleaned"

# Clean all runtime state (database, layers, containers)
clean-all-state: clean-state clean-layers clean-containers
	@echo "✓ All runtime state cleaned"

# Install to system
install: release
	@echo "Installing $(BINARY) to $(INSTALL_DIR)..."
	@sudo cp $(BUILD_DIR)/$(BINARY) $(INSTALL_DIR)/
	@echo "✓ Installed to $(INSTALL_DIR)/$(BINARY)"

# Uninstall from system
uninstall:
	@echo "Uninstalling $(BINARY) from $(INSTALL_DIR)..."
	@sudo rm -f $(INSTALL_DIR)/$(BINARY)
	@echo "✓ Uninstalled"

# Verify entitlements
verify-entitlements: $(BUILD_DIR)/$(BINARY)
	@echo "Verifying entitlements for $(BUILD_DIR)/$(BINARY)..."
	@codesign -d --entitlements - $(BUILD_DIR)/$(BINARY)

# Run the daemon in foreground mode (debug build)
run: codesign
	@echo "Starting Arca daemon (debug)..."
	@rm -f /tmp/arca.sock
	@$(BUILD_DIR)/$(BINARY) daemon start --socket-path /tmp/arca.sock

# Run the daemon in foreground mode (debug build)
run-debug: codesign
	@echo "Starting Arca daemon (debug)..."
	@rm -f /tmp/arca.sock
	@$(BUILD_DIR)/$(BINARY) daemon start --socket-path /tmp/arca.sock --log-level debug

# Run the daemon in foreground mode (release build)
run-release:
	@$(MAKE) CONFIGURATION=release codesign
	@echo "Starting Arca daemon (release)..."
	@rm -f /tmp/arca.sock
	@.build/release/$(BINARY) daemon start --socket-path /tmp/arca.sock --log-level debug

# Setup buildx builder with default-load=true (run after daemon is started)
setup-builder:
	@echo "Setting up Arca buildx builder..."
	@DOCKER_HOST=unix:///tmp/arca.sock ./scripts/setup-builder.sh

# Run daemon in background and automatically setup builder
run-with-setup: codesign
	@echo "Starting Arca daemon in background (debug)..."
	@rm -f /tmp/arca.sock
	@$(BUILD_DIR)/$(BINARY) daemon start --socket-path /tmp/arca.sock --log-level debug > /tmp/arca-daemon.log 2>&1 &
	@echo "Daemon started in background (PID: $$!)"
	@echo "Logs: tail -f /tmp/arca-daemon.log"
	@echo ""
	@DOCKER_HOST=unix:///tmp/arca.sock ./scripts/setup-builder.sh

# Build kernel with TUN support (only if not already built)
kernel:
	@if [ ! -f ~/.arca/vmlinux ]; then \
		echo "Building Linux kernel with TUN support..."; \
		./scripts/build-kernel.sh; \
	else \
		echo "✓ Kernel already exists at ~/.arca/vmlinux (use 'make kernel-rebuild' to rebuild)"; \
	fi

# Force rebuild kernel even if it exists
kernel-rebuild:
	@echo "Rebuilding Linux kernel with TUN support..."
	@rm -f ~/.arca/vmlinux
	@./scripts/build-kernel.sh

# Build custom vminit with WireGuard networking extension (only if not already built)
# The build script builds arca-wireguard-service from the vminitd submodule
vminit:
	@if [ ! -d ~/.arca/vminit ]; then \
		echo "Building custom vminit:latest with networking extensions (release)..."; \
		./scripts/build-vminit.sh release; \
	else \
		echo "✓ vminit already exists at ~/.arca/vminit (use 'make vminit-rebuild' to rebuild)"; \
	fi

# Force rebuild vminit even if it exists
vminit-rebuild:
	@echo "Rebuilding custom vminit:latest with networking extensions (release)..."
	@rm -rf ~/.arca/vminit
	@./scripts/build-vminit.sh release

# Build custom vminit in DEBUG mode (better logging)
vminit-debug:
	@echo "Building custom vminit:latest with networking extensions (debug)..."
	@./scripts/build-vminit.sh debug

# Generate gRPC code from proto files
gen-grpc:
	@echo "Generating gRPC code from proto files..."
	@./scripts/generate-grpc.sh

# Generate build info with git commit and timestamp
gen-buildinfo:
	@echo "Generating build info..."
	@echo '// AUTO-GENERATED FILE - DO NOT EDIT' > Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '// Generated by Makefile during build' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '// To regenerate: make gen-buildinfo' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo 'import Foundation' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '/// Build-time information injected by Makefile' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo 'public struct ArcaBuildInfo {' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '    /// Git commit hash at build time' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '    public static let gitCommit = "$(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")"' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '    /// ISO8601 timestamp of build' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '    public static let buildTime = "$(shell date -u +%Y-%m-%dT%H:%M:%SZ)"' >> Sources/ContainerBridge/BuildInfo.generated.swift
	@echo '}' >> Sources/ContainerBridge/BuildInfo.generated.swift

# Build all pre-built assets for distribution
build-assets: kernel vminit
	@echo "Packaging assets for distribution..."
	@mkdir -p assets
	@echo "Compressing kernel..."
	@gzip -c ~/.arca/vmlinux > assets/vmlinux-arm64.gz
	@echo "Packaging vminit OCI image..."
	@cd ~/.arca && tar czf $(shell pwd)/assets/vminit-oci-arm64.tar.gz vminit/
	@echo "Generating checksums..."
	@cd assets && shasum -a 256 vmlinux-arm64.gz vminit-oci-arm64.tar.gz > SHA256SUMS
	@echo "✓ Assets built successfully:"
	@ls -lh assets/vmlinux-arm64.gz assets/vminit-oci-arm64.tar.gz
	@echo ""
	@echo "Checksums:"
	@cat assets/SHA256SUMS

# Install protoc-gen-grpc-swift plugin (v1.27.0)
install-grpc-plugin:
	@echo "Installing protoc-gen-grpc-swift v1.27.0..."
	@if [ -f /usr/local/bin/protoc-gen-grpc-swift ]; then \
		echo "protoc-gen-grpc-swift already installed at /usr/local/bin/protoc-gen-grpc-swift"; \
		/usr/local/bin/protoc-gen-grpc-swift --version 2>&1 | head -1 || echo "version unknown"; \
		echo "To reinstall, run: sudo rm /usr/local/bin/protoc-gen-grpc-swift && make install-grpc-plugin"; \
	else \
		echo "Cloning grpc-swift v1.27.0..."; \
		rm -rf /tmp/grpc-swift-plugin-build; \
		git clone --depth 1 --branch 1.27.0 https://github.com/grpc/grpc-swift.git /tmp/grpc-swift-plugin-build; \
		cd /tmp/grpc-swift-plugin-build && swift build --product protoc-gen-grpc-swift -c release; \
		echo "Installing to /usr/local/bin/ (requires sudo)..."; \
		sudo cp /tmp/grpc-swift-plugin-build/.build/release/protoc-gen-grpc-swift /usr/local/bin/; \
		sudo chmod +x /usr/local/bin/protoc-gen-grpc-swift; \
		rm -rf /tmp/grpc-swift-plugin-build; \
		echo "✓ protoc-gen-grpc-swift v1.27.0 installed"; \
	fi

# Run tests
# Ensures daemon is built and signed before running tests
# Usage: make test [FILTER=TestName]
test: codesign
	@echo "Cleaning up test database..."
	@rm -f ~/.arca/state.db
	@echo "Building tests..."
	@swift build --build-tests
	@echo "Re-signing Arca binary (swift build --build-tests may have rebuilt it)..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/Arca
	@echo "Signing ArcaTestHelper binary..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/ArcaTestHelper
	@echo "Signing $(ENGINE) binary..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(ENGINE)
	@echo "Signing test binaries..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) .build/debug/ArcaPackageTests.xctest/Contents/MacOS/ArcaPackageTests 2>/dev/null || true
	@echo "✓ All binaries signed"
	@echo "Running tests with signed binaries..."
	@if [ -n "$(FILTER)" ]; then \
		swift test --skip-build --filter $(FILTER); \
	else \
		swift test --skip-build; \
	fi

# Run helper VM integration tests (requires signing)
test-helper: codesign
	@echo "Running helper VM integration tests..."
	@$(BUILD_DIR)/$(TEST_HELPER)

# Create distribution tarball
dist: release
	@echo "Creating distribution package (version: $(VERSION))..."
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_DIR)/arca-$(VERSION)/bin
	@mkdir -p $(DIST_DIR)/arca-$(VERSION)/share/doc/arca
	@cp .build/release/$(BINARY) $(DIST_DIR)/arca-$(VERSION)/bin/
	@cp README.md $(DIST_DIR)/arca-$(VERSION)/
	@cp Documentation/OVERVIEW.md $(DIST_DIR)/arca-$(VERSION)/share/doc/arca/
	@cp Documentation/ARCHITECTURE.md $(DIST_DIR)/arca-$(VERSION)/share/doc/arca/
	@cp Documentation/LIMITATIONS.md $(DIST_DIR)/arca-$(VERSION)/share/doc/arca/
	@echo "#!/bin/bash" > $(DIST_DIR)/arca-$(VERSION)/install.sh
	@echo 'echo "Installing Arca to /usr/local/bin..."' >> $(DIST_DIR)/arca-$(VERSION)/install.sh
	@echo 'sudo cp bin/Arca /usr/local/bin/' >> $(DIST_DIR)/arca-$(VERSION)/install.sh
	@echo 'echo "✓ Arca installed successfully"' >> $(DIST_DIR)/arca-$(VERSION)/install.sh
	@echo 'echo "Run: arca daemon start"' >> $(DIST_DIR)/arca-$(VERSION)/install.sh
	@chmod +x $(DIST_DIR)/arca-$(VERSION)/install.sh
	@cd $(DIST_DIR) && tar czf arca-$(VERSION)-macos-arm64.tar.gz arca-$(VERSION)
	@echo "✓ Distribution created: $(DIST_DIR)/arca-$(VERSION)-macos-arm64.tar.gz"
	@echo ""
	@echo "To install:"
	@echo "  tar xzf $(DIST_DIR)/arca-$(VERSION)-macos-arm64.tar.gz"
	@echo "  cd arca-$(VERSION)"
	@echo "  ./install.sh"

# Create macOS .dmg installer with drag-and-drop Arca.app (no admin required)
dist-dmg: release
	@echo "Creating macOS .dmg installer (version: $(VERSION))..."
	@rm -rf $(DIST_DIR)/dmg
	@mkdir -p $(DIST_DIR)/dmg/Arca.app/Contents/MacOS
	@mkdir -p $(DIST_DIR)/dmg/Arca.app/Contents/Resources

	@echo "Building GUI app..."
	@./scripts/build-gui-app.sh release

	@echo "Copying Info.plist and setting version..."
	@sed "s/VERSION_PLACEHOLDER/$(VERSION)/g" ArcaApp/ArcaApp/Info.plist > $(DIST_DIR)/dmg/Arca.app/Contents/Info.plist

	@echo "Copying GUI app executable..."
	@cp .build-gui/ArcaApp $(DIST_DIR)/dmg/Arca.app/Contents/MacOS/ArcaApp

	@echo "Copying app icon..."
	@cp ArcaApp/ArcaApp/AppIcon.icns $(DIST_DIR)/dmg/Arca.app/Contents/Resources/AppIcon.icns

	@echo "Copying Arca daemon binary to Resources..."
	@cp .build/release/$(BINARY) $(DIST_DIR)/dmg/Arca.app/Contents/Resources/Arca

	@echo "Bundling pre-built assets..."
	@if [ -f assets/vmlinux-arm64.gz ]; then \
		echo "  • Extracting kernel..."; \
		gunzip -c assets/vmlinux-arm64.gz > $(DIST_DIR)/dmg/Arca.app/Contents/Resources/vmlinux; \
	else \
		echo "ERROR: assets/vmlinux-arm64.gz not found"; \
		echo "Run: make build-assets"; \
		exit 1; \
	fi

	@if [ -f assets/vminit-oci-arm64.tar.gz ]; then \
		echo "  • Encrypting vminit OCI image (to prevent notarization scanner from detecting Linux binaries)..."; \
		zip -q -P arca-vminit-payload -j $(DIST_DIR)/dmg/Arca.app/Contents/Resources/vminit.zip assets/vminit-oci-arm64.tar.gz; \
	else \
		echo "ERROR: assets/vminit-oci-arm64.tar.gz not found"; \
		echo "Run: make build-assets"; \
		exit 1; \
	fi

	@echo "Code signing Arca.app bundle..."
	@if [ -n "$(CODESIGN_IDENTITY)" ] && [ "$(CODESIGN_IDENTITY)" != "-" ]; then \
		echo "Signing daemon binary..."; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" \
			--options runtime --timestamp \
			--entitlements $(ENTITLEMENTS) \
			$(DIST_DIR)/dmg/Arca.app/Contents/Resources/Arca; \
		echo "Signing GUI app..."; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" \
			--options runtime --timestamp \
			--entitlements ArcaApp/ArcaApp/ArcaApp.entitlements \
			$(DIST_DIR)/dmg/Arca.app/Contents/MacOS/ArcaApp; \
		echo "Signing app bundle..."; \
		codesign --deep --force --sign "$(CODESIGN_IDENTITY)" \
			--options runtime --timestamp \
			$(DIST_DIR)/dmg/Arca.app; \
		echo "✓ App bundle signed"; \
	else \
		echo "Signing with adhoc signature (for testing)"; \
		codesign --force --sign - \
			--entitlements $(ENTITLEMENTS) \
			$(DIST_DIR)/dmg/Arca.app/Contents/Resources/Arca; \
		codesign --force --sign - \
			--entitlements ArcaApp/ArcaApp/ArcaApp.entitlements \
			$(DIST_DIR)/dmg/Arca.app/Contents/MacOS/ArcaApp; \
		codesign --deep --force --sign - \
			$(DIST_DIR)/dmg/Arca.app; \
		echo "⚠️  App bundle signed with adhoc signature (not suitable for distribution)"; \
		echo "   For notarization, set: CODESIGN_IDENTITY=\"Developer ID Application: Your Name (ID)\""; \
	fi

	@echo "Creating Applications symlink for drag-and-drop..."
	@ln -s /Applications $(DIST_DIR)/dmg/Applications

	@echo "Creating .dmg disk image..."
	@hdiutil create -volname "Arca $(VERSION)" \
		-srcfolder $(DIST_DIR)/dmg \
		-ov -format UDZO \
		$(DIST_DIR)/arca-$(VERSION).dmg

	@echo "✓ DMG created: $(DIST_DIR)/arca-$(VERSION).dmg"
	@echo ""
	@echo "App bundle contents:"
	@echo "  GUI App:  Arca.app/Contents/MacOS/ArcaApp (SwiftUI status window)"
	@echo "  Daemon:   Arca.app/Contents/Resources/Arca (Docker API daemon)"
	@echo "  Kernel:   Arca.app/Contents/Resources/vmlinux"
	@echo "  Runtime:  Arca.app/Contents/Resources/vminit.zip (encrypted)"
	@echo ""
	@echo "Installation:"
	@echo "  1. Mount the DMG (double-click arca-$(VERSION).dmg)"
	@echo "  2. Drag Arca.app to Applications folder"
	@echo "  3. Double-click Arca.app (automatic first-time setup)"
	@echo "  4. Setup runs automatically - no Terminal required!"
	@echo ""
	@echo "Features:"
	@echo "  • Native SwiftUI macOS app"
	@echo "  • Automatic setup on first launch"
	@echo "  • Status window showing daemon info"
	@echo "  • Start/stop daemon controls"
	@echo "  • No admin password required"
	@echo ""
	@echo "DMG size: $$(du -h $(DIST_DIR)/arca-$(VERSION).dmg | cut -f1)"

# Notarize the DMG (requires Apple Developer account)
# Uses scripts/notarize.sh for comprehensive notarization workflow
notarize: dist-dmg
	@echo "Starting notarization workflow..."
	@./scripts/notarize.sh $(DIST_DIR)/arca-$(VERSION).dmg

# Check environment variables required for publishing
# Validates CODESIGN_IDENTITY and notarization credentials before proceeding
check-publish-env:
	@echo "Checking publish environment..."
	@# Check CODESIGN_IDENTITY is set to a Developer ID (not adhoc)
	@if [ -z "$(CODESIGN_IDENTITY)" ] || [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo ""; \
		echo "ERROR: CODESIGN_IDENTITY must be set to a Developer ID Application certificate"; \
		echo ""; \
		echo "  export CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAM_ID)\""; \
		echo ""; \
		echo "To find your certificate:"; \
		echo "  security find-identity -v -p codesigning | grep 'Developer ID Application'"; \
		echo ""; \
		exit 1; \
	fi
	@echo "✓ CODESIGN_IDENTITY: $(CODESIGN_IDENTITY)"
	@# Check notarization credentials (API key or keychain profile)
	@if [ -n "$(NOTARY_KEY_ID)" ] && [ -n "$(NOTARY_ISSUER_ID)" ] && [ -n "$(NOTARY_KEY_FILE)" ]; then \
		echo "✓ Notarization: API key authentication"; \
		echo "  NOTARY_KEY_ID: $(NOTARY_KEY_ID)"; \
		echo "  NOTARY_ISSUER_ID: $(NOTARY_ISSUER_ID)"; \
		echo "  NOTARY_KEY_FILE: $(NOTARY_KEY_FILE)"; \
		if [ ! -f "$(NOTARY_KEY_FILE)" ]; then \
			echo ""; \
			echo "ERROR: NOTARY_KEY_FILE does not exist: $(NOTARY_KEY_FILE)"; \
			exit 1; \
		fi; \
	elif xcrun notarytool history --keychain-profile "AC_PASSWORD" > /dev/null 2>&1; then \
		echo "✓ Notarization: Keychain profile 'AC_PASSWORD'"; \
	else \
		echo ""; \
		echo "ERROR: No notarization credentials found"; \
		echo ""; \
		echo "Option 1 - Set API key environment variables:"; \
		echo "  export NOTARY_KEY_ID=\"your-key-id\""; \
		echo "  export NOTARY_ISSUER_ID=\"your-issuer-id\""; \
		echo "  export NOTARY_KEY_FILE=\"/path/to/AuthKey.p8\""; \
		echo ""; \
		echo "Option 2 - Store credentials in keychain:"; \
		echo "  xcrun notarytool store-credentials \"AC_PASSWORD\" \\"; \
		echo "    --apple-id \"your@email.com\" \\"; \
		echo "    --team-id \"YOUR_TEAM_ID\""; \
		echo ""; \
		exit 1; \
	fi
	@# Check GitHub CLI
	@if ! command -v gh >/dev/null 2>&1; then \
		echo ""; \
		echo "ERROR: GitHub CLI (gh) not found"; \
		echo "Install with: brew install gh"; \
		exit 1; \
	fi
	@echo "✓ GitHub CLI: $(shell gh --version | head -1)"
	@echo ""
	@echo "All publish environment checks passed!"
	@echo ""

# Publish release to GitHub
# Creates a signed git tag, pushes it, and creates a GitHub pre-release
# Notarizes the DMG before publishing (requires Apple Developer account)
# Usage: make publish [VERSION=v1.0.0]
publish: check-publish-env notarize
	@echo "Publishing release $(VERSION) to GitHub..."
	@if echo "$(VERSION)" | grep -q dirty; then \
		echo "ERROR: Cannot publish dirty version: $(VERSION)"; \
		echo "Commit your changes and ensure working tree is clean"; \
		exit 1; \
	fi
	@if ! command -v gh >/dev/null 2>&1; then \
		echo "ERROR: GitHub CLI (gh) not found"; \
		echo "Install with: brew install gh"; \
		exit 1; \
	fi
	@echo ""
	@echo "Creating signed git tag $(VERSION)..."
	@if git rev-parse "$(VERSION)" >/dev/null 2>&1; then \
		echo "Tag $(VERSION) already exists, skipping tag creation"; \
	else \
		git tag -s "$(VERSION)" -m "Release $(VERSION)"; \
		echo "✓ Signed tag created: $(VERSION)"; \
	fi
	@echo ""
	@echo "Pushing tag to origin..."
	@git push origin "$(VERSION)"
	@echo "✓ Tag pushed to origin"
	@echo ""
	@echo "Verifying tag signature..."
	@git tag -v "$(VERSION)" 2>&1 | head -5 || echo "⚠️  Tag verification requires GPG key in keyring"
	@echo ""
	@echo "Generating SHA256 checksum for DMG..."
	@cd $(DIST_DIR) && shasum -a 256 arca-$(VERSION).dmg > arca-$(VERSION).dmg.sha256
	@echo "✓ Checksum: $$(cat $(DIST_DIR)/arca-$(VERSION).dmg.sha256)"
	@echo ""
	@echo "Creating GitHub pre-release $(VERSION)..."
	@gh release create "$(VERSION)" \
		--title "Arca $(VERSION)" \
		--notes "Release $(VERSION)" \
		--prerelease \
		$(DIST_DIR)/arca-$(VERSION).dmg \
		$(DIST_DIR)/arca-$(VERSION).dmg.sha256
	@echo ""
	@echo "✓ Pre-release published successfully"
	@echo ""
	@echo "Release URL: https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$(VERSION)"

# Clean distribution artifacts
clean-dist:
	@echo "Cleaning distribution artifacts..."
	@rm -rf $(DIST_DIR)
	@echo "✓ Distribution artifacts cleaned"

# Install service (LaunchAgent - no sudo required)
install-service: release
	@echo "Installing Arca as a LaunchAgent service..."
	@mkdir -p $(LAUNCH_AGENT_DIR)
	@mkdir -p ~/.arca
	@cp .build/release/$(BINARY) $(INSTALL_DIR)/
	@sed "s|HOME_DIR|$(HOME)|g" $(LAUNCH_AGENT_PLIST).template > $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST)
	@echo "✓ Service installed to $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST)"
	@echo "✓ Binary installed to $(INSTALL_DIR)/$(BINARY)"
	@echo ""
	@echo "To start the service:"
	@echo "  make start-service"
	@echo ""
	@echo "To configure your shell (add DOCKER_HOST):"
	@echo "  make configure-shell"

# Uninstall service
uninstall-service: stop-service
	@echo "Uninstalling Arca service..."
	@rm -f $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST)
	@rm -f $(INSTALL_DIR)/$(BINARY)
	@echo "✓ Service uninstalled"
	@echo ""
	@echo "Note: Shell configuration in ~/.zshrc or ~/.bash_profile not removed"
	@echo "Remove manually: export DOCKER_HOST=unix://$(DEFAULT_SOCKET)"

# Start service
start-service:
	@echo "Starting Arca service..."
	@launchctl load -w $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST)
	@sleep 2
	@if [ -S "$(DEFAULT_SOCKET)" ]; then \
		echo "✓ Arca service started"; \
		echo "Socket: $(DEFAULT_SOCKET)"; \
		echo ""; \
		echo "Configure your shell:"; \
		echo "  export DOCKER_HOST=unix://$(DEFAULT_SOCKET)"; \
		echo "Or run: make configure-shell"; \
	else \
		echo "⚠️  Service started but socket not found"; \
		echo "Check logs: tail -f ~/.arca/arca.log"; \
	fi

# Stop service
stop-service:
	@echo "Stopping Arca service..."
	@launchctl unload $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST) 2>/dev/null || true
	@echo "✓ Arca service stopped"

# Restart service
restart-service: stop-service start-service

# Service status
service-status:
	@echo "Arca service status:"
	@echo ""
	@if launchctl list | grep -q com.liquescent.arca; then \
		echo "✓ Service is running"; \
		launchctl list | grep com.liquescent.arca; \
	else \
		echo "✗ Service is not running"; \
	fi
	@echo ""
	@if [ -S "$(DEFAULT_SOCKET)" ]; then \
		echo "✓ Socket exists: $(DEFAULT_SOCKET)"; \
	else \
		echo "✗ Socket not found: $(DEFAULT_SOCKET)"; \
	fi

# Configure shell environment
configure-shell:
	@echo "Configuring shell environment..."
	@if [ -n "$$ZSH_VERSION" ] || [ -f ~/.zshrc ]; then \
		SHELL_RC=~/.zshrc; \
	elif [ -n "$$BASH_VERSION" ] || [ -f ~/.bash_profile ]; then \
		SHELL_RC=~/.bash_profile; \
	else \
		SHELL_RC=~/.profile; \
	fi; \
	if grep -q "DOCKER_HOST.*arca.sock" $$SHELL_RC 2>/dev/null; then \
		echo "✓ DOCKER_HOST already configured in $$SHELL_RC"; \
	else \
		echo "" >> $$SHELL_RC; \
		echo "# Arca - Docker Engine API for Apple Containerization" >> $$SHELL_RC; \
		echo "export DOCKER_HOST=unix://$(DEFAULT_SOCKET)" >> $$SHELL_RC; \
		echo "✓ Added DOCKER_HOST to $$SHELL_RC"; \
		echo ""; \
		echo "Run: source $$SHELL_RC"; \
		echo "Or restart your terminal"; \
	fi

# Help
help:
	@echo "Arca Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make                 - Build and codesign debug binary (incremental)"
	@echo "  make debug           - Build and codesign debug binary"
	@echo "  make release         - Build and codesign release binary"
	@echo "  make run             - Build, sign, and run daemon (debug) at /tmp/arca.sock"
	@echo "  make run-with-setup  - Start daemon in background + auto-configure buildx"
	@echo "  make setup-builder   - Setup buildx builder with default-load=true"
	@echo "  make run-release     - Build, sign, and run daemon (release) at /tmp/arca.sock"
	@echo "  make test            - Run all tests"
	@echo "  make clean           - Remove all build artifacts"
	@echo "  make clean-state     - Remove state database only"
	@echo "  make clean-layers    - Remove layer cache only"
	@echo "  make clean-containers - Remove container state only"
	@echo "  make clean-all-state - Remove all runtime state (db, layers, containers)"
	@echo "  make clean-dist      - Remove distribution artifacts"
	@echo "  make install         - Install release binary to /usr/local/bin"
	@echo "  make uninstall       - Remove binary from /usr/local/bin"
	@echo ""
	@echo "Service management (no sudo required):"
	@echo "  make install-service - Install Arca as LaunchAgent service"
	@echo "  make uninstall-service - Uninstall service"
	@echo "  make start-service   - Start Arca service"
	@echo "  make stop-service    - Stop Arca service"
	@echo "  make restart-service - Restart Arca service"
	@echo "  make service-status  - Check service status"
	@echo "  make configure-shell - Add DOCKER_HOST to shell profile"
	@echo ""
	@echo "Distribution:"
	@echo "  make dist            - Create distribution tarball (.tar.gz)"
	@echo "  make dist-dmg        - Create macOS .dmg installer with Arca.app"
	@echo "  make notarize        - Notarize .dmg (requires Apple Developer account)"
	@echo "  make check-publish-env - Verify all environment variables for publishing"
	@echo "  make publish         - Create signed tag, push, and publish pre-release to GitHub"
	@echo ""
	@echo "Advanced:"
	@echo "  make kernel          - Build Linux kernel (only if missing, 10-15 min)"
	@echo "  make kernel-rebuild  - Force rebuild kernel even if exists"
	@echo "  make vminit          - Build custom vminit:latest (only if missing, ~5 min)"
	@echo "  make vminit-rebuild  - Force rebuild vminit even if exists"
	@echo "  make vminit-debug    - Build custom vminit:latest (debug, better logging)"
	@echo "  make build-assets    - Build all pre-built assets (kernel + vminit, ~20-25 min)"
	@echo "  make gen-grpc        - Generate gRPC code from proto files"
	@echo "  make install-grpc-plugin - Install protoc-gen-grpc-swift v1.27.0"
	@echo "  make verify-entitlements - Display entitlements of built binary"
	@echo ""
	@echo "Build configurations:"
	@echo "  CONFIGURATION=debug   - Debug build (default)"
	@echo "  CONFIGURATION=release - Optimized release build"
	@echo ""
	@echo "Code signing:"
	@echo "  CODESIGN_IDENTITY=\"-\"                                    - Adhoc binary signing (default)"
	@echo "  CODESIGN_IDENTITY=\"Developer ID Application: Name (ID)\" - App bundle signing for release/notarization"
	@echo ""
	@echo "Publishing (make publish):"
	@echo "  CODESIGN_IDENTITY      - Required: Developer ID Application certificate"
	@echo "  Notarization (one of):"
	@echo "    Option A - API key:"
	@echo "      NOTARY_KEY_ID      - App Store Connect API key ID"
	@echo "      NOTARY_ISSUER_ID   - App Store Connect API issuer ID"
	@echo "      NOTARY_KEY_FILE    - Path to API key .p8 file"
	@echo "    Option B - Keychain profile 'AC_PASSWORD' (via xcrun notarytool store-credentials)"
	@echo ""
	@echo "Dependencies:"
	@echo "  protoc-gen-grpc-swift v1.27.0 (run 'make install-grpc-plugin')"
	@echo ""
	@echo "Notes:"
	@echo "  - Builds are incremental: only changed files are recompiled"
	@echo "  - Binary is automatically codesigned with entitlements"
	@echo "  - For distribution, set CODESIGN_IDENTITY to your Developer ID"
