# Jarvis macOS — reproducible build entry points.
#
# One-time setup on a fresh machine:
#   brew bundle            # installs mint (+ optional tools)
#   make bootstrap         # installs the pinned XcodeGen via mint
#
# Everyday:
#   make generate          # regenerate JarvisMac.xcodeproj from project.yml
#   make resolve           # resolve SPM deps and refresh the committed Package.resolved
#   make build             # Debug build (ad-hoc signed)
#   make test              # run JarvisMacTests + JarvisBrainDaemonTests
#
# Release / notarization is documented in BUILD.md (needs a Developer ID + team).

SCHEME      := JarvisMac
PROJECT     := JarvisMac.xcodeproj
XCODEGEN    := mint run xcodegen
DERIVED     := build/DerivedData
RESOLVED_SRC := $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

.PHONY: bootstrap generate resolve build test clean

# Install the exact XcodeGen pinned in Mintfile.
bootstrap:
	mint bootstrap

# Generate the Xcode project from project.yml.
generate: $(PROJECT)
$(PROJECT): project.yml
	$(XCODEGEN) generate

# Resolve SPM dependencies and copy the lockfile out to a committed location.
# Run this on a Mac after bumping a dependency, then commit Package.resolved.
resolve: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -resolvePackageDependencies \
		-derivedDataPath $(DERIVED)
	@if [ -f "$(RESOLVED_SRC)" ]; then \
		cp "$(RESOLVED_SRC)" Package.resolved; \
		echo "Updated Package.resolved"; \
	else \
		echo "WARNING: $(RESOLVED_SRC) not found — nothing copied"; \
	fi

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) test

clean:
	rm -rf $(DERIVED) $(PROJECT)
