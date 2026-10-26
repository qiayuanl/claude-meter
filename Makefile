# With only the Command Line Tools selected, Swift Testing sits outside the default framework
# search path. The flags add that path (-F), skip its Foundation cross-import overlay, which
# ships without a module, and let the test runner load the framework at run time (rpath).
CLT := /Library/Developer/CommandLineTools
CLT_FRAMEWORKS := $(CLT)/Library/Developer/Frameworks
TEST_FLAGS := $(if $(filter $(CLT),$(shell xcode-select -p)),\
	-Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
	-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS))

.PHONY: build test app install

build:
	swift build

test:
	swift test $(TEST_FLAGS)

app:
	scripts/build-app.sh

install:
	scripts/build-app.sh --install
