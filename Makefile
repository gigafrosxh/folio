.PHONY: build test app run install installer release clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run:
	./scripts/build-app.sh --run

install:
	./scripts/build-app.sh --install

installer:
	./scripts/make-installer.sh

# make release V=patch|minor|major|X.Y.Z
release:
	./scripts/release.sh $(V)

clean:
	swift package clean
	rm -rf build/Folio.app
