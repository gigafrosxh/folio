.PHONY: build test app run install clean

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

clean:
	swift package clean
	rm -rf build/Folio.app
