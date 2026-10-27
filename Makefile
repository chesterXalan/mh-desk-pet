# Command Line Tools ship Swift Testing outside the default search paths, so tests need these flags.
DEV_FRAMEWORKS := $(shell xcode-select -p)/Library/Developer/Frameworks
DEV_LIB := $(shell xcode-select -p)/Library/Developer/usr/lib
TEST_FLAGS := --build-system native -Xswiftc -F -Xswiftc $(DEV_FRAMEWORKS) \
	-Xlinker -F -Xlinker $(DEV_FRAMEWORKS) -Xlinker -rpath -Xlinker $(DEV_FRAMEWORKS) -Xlinker -rpath -Xlinker $(DEV_LIB)

.PHONY: app test sprites preview catalog run clean

app:
	./scripts/build-app.sh

test:
	swift test $(TEST_FLAGS)

sprites:
	swift tools/build-monsters.swift .

preview:
	swift tools/build-preview.swift

catalog:
	swift tools/build-catalog.swift

run: app
	open build/DeskPets.app

clean:
	rm -rf build .build
