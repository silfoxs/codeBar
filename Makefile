APP_NAME := codeBar
APP_EXECUTABLE := codeBar
APP_BUNDLE := $(APP_NAME).app
DIST_DIR := dist

.PHONY: build test run dev logs package dmg clean check

build:
	swift build

test:
	swift test

run:
	swift run $(APP_EXECUTABLE)

dev:
	./scripts/dev.sh

logs:
	./scripts/logs.sh

package:
	./scripts/package-app.sh

dmg: package
	./scripts/create-dmg.sh

check:
	swift package describe
	swift build -c release

clean:
	swift package clean
	rm -rf $(DIST_DIR)
