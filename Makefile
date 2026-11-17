CODEC := .build/sbc-2.1
ARCHIVE := $(CODEC).tar.xz
LIB := .build/libsbc.a
FLAGS := -Wall -Wextra -O2 -I$(CODEC) -Isrc
FRAMEWORKS := -framework Foundation -framework IOKit -lz

.PHONY: all test record
all: .build/ds4-mic

$(ARCHIVE):
	@mkdir -p .build
	curl -fL https://www.kernel.org/pub/linux/bluetooth/sbc-2.1.tar.xz -o $@.part
	mv $@.part $@

$(LIB): $(ARCHIVE)
	echo '426633cabd7c798236443516dfa8335b47e004b0ef37ff107e0c7ead3299fcc2  $(ARCHIVE)' | shasum -a 256 -c -
	tar -xf $(ARCHIVE) -C .build
	$(CC) -O2 -DSBC_HIGH_PRECISION -c $(CODEC)/sbc/sbc.c -o .build/sbc.o
	$(CC) -O2 -DSBC_HIGH_PRECISION -c $(CODEC)/sbc/sbc_primitives.c -o .build/sbc_primitives.o
	ar rcs $@ .build/sbc.o .build/sbc_primitives.o

.build/ds4-mic: src/main.m src/DS4HID.m src/DS4HID.h src/Capture.m src/Capture.h $(LIB)
	$(CC) $(FLAGS) -fobjc-arc src/main.m src/DS4HID.m src/Capture.m $(LIB) $(FRAMEWORKS) -o $@

.build/test-capture: tests/capture.m src/Capture.m src/Capture.h src/VoiceLevel.m src/VoiceLevel.h $(LIB)
	$(CC) $(FLAGS) -fobjc-arc tests/capture.m src/Capture.m src/VoiceLevel.m $(LIB) $(FRAMEWORKS) -o $@

test: .build/test-capture
	.build/test-capture
	python3 tests/voice.py

record: .build/ds4-mic
	.build/ds4-mic --play

APP := DualShock\ Playground.app
APPDIR := DualShock Playground.app/Contents
.PHONY: playground
playground: $(APP)/Contents/_CodeSignature/CodeResources

$(APP)/Contents/_CodeSignature/CodeResources: playground/App.m src/HeadsetMic.m src/HeadsetMic.h src/VoiceLevel.m src/VoiceLevel.h playground/index.html playground/ui.js playground/pad.js playground/style.css playground/Info.plist speech.py src/Capture.m src/Capture.h src/DS4HID.m src/DS4HID.h $(LIB)
	mkdir -p "$(APPDIR)/MacOS" "$(APPDIR)/Resources"
	$(CC) $(FLAGS) -fobjc-arc playground/App.m src/HeadsetMic.m src/VoiceLevel.m src/DS4HID.m src/Capture.m $(LIB) $(FRAMEWORKS) -framework Cocoa -framework WebKit -o "$(APPDIR)/MacOS/Playground"
	cp playground/Info.plist "$(APPDIR)/Info.plist"
	cp playground/index.html playground/pad.js playground/ui.js playground/style.css speech.py "$(APPDIR)/Resources/"
	codesign --force --sign - "DualShock Playground.app"

PAD := Herdr\ Pad.app
PADDIR := Herdr Pad.app/Contents
PAD_SOURCES := hud/App.m hud/Herdr.m hud/SystemMic.m src/HeadsetMic.m src/VoiceLevel.m src/DS4HID.m src/Capture.m
.PHONY: pad
pad: $(PAD)/Contents/_CodeSignature/CodeResources

$(PAD)/Contents/_CodeSignature/CodeResources: $(PAD_SOURCES) hud/Herdr.h hud/SystemMic.h src/HeadsetMic.h src/Capture.h src/DS4HID.h src/VoiceLevel.h hud/hud.html hud/hud.js hud/hud.css hud/Info.plist speech.py $(wildcard hud/AppIcon.icns) $(LIB)
	mkdir -p "$(PADDIR)/MacOS" "$(PADDIR)/Resources"
	$(CC) $(FLAGS) -Ihud -fobjc-arc $(PAD_SOURCES) $(LIB) $(FRAMEWORKS) -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreAudio -o "$(PADDIR)/MacOS/HerdrPad"
	cp hud/Info.plist "$(PADDIR)/Info.plist"
	cp hud/hud.html hud/hud.js hud/hud.css speech.py "$(PADDIR)/Resources/"
	if [ -f hud/AppIcon.icns ]; then cp hud/AppIcon.icns "$(PADDIR)/Resources/"; fi
	codesign --force --sign - "Herdr Pad.app"

# The Herdr app layout lives in herdr-app/ (the folder herdr.dev/gallery lists).
# `make helper` rebuilds the bundled controller helper into it; `make install-layout`
# copies the layout, the pad mod and the theme into the Herdr app.
.PHONY: helper install-layout
helper: .build/herdr-pad
	cp .build/herdr-pad herdr-app/mods/pad/herdr-pad
	rsync -a --delete .build/herdr-pad.resources/ herdr-app/mods/pad/herdr-pad.resources/

install-layout: helper
	herdr-app/install.sh

# The same helper as a bare binary: Info.plist linked in, files in herdr-pad.resources/.
.build/herdr-pad: $(PAD_SOURCES) hud/Herdr.h hud/SystemMic.h src/HeadsetMic.h src/Capture.h src/DS4HID.h src/VoiceLevel.h hud/Info-binary.plist hud/hud.html hud/hud.js hud/hud.css speech.py $(LIB)
	$(CC) $(FLAGS) -Ihud -fobjc-arc $(PAD_SOURCES) $(LIB) $(FRAMEWORKS) -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreAudio -sectcreate __TEXT __info_plist hud/Info-binary.plist -o $@
	mkdir -p .build/herdr-pad.resources
	cp hud/hud.html hud/hud.js hud/hud.css speech.py .build/herdr-pad.resources/
