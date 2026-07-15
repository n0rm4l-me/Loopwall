APP_NAME = Loopwall
BUNDLE   = $(APP_NAME).app
BINARY   = .build/release/$(APP_NAME)
PLIST    = Sources/Loopwall/Info.plist
ICON     = Sources/Loopwall/AppIcon.icns

.PHONY: app build clean

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp $(PLIST)  $(BUNDLE)/Contents/Info.plist
	cp $(ICON)   $(BUNDLE)/Contents/Resources/AppIcon.icns

build:
	swift build -c release

clean:
	rm -rf .build $(BUNDLE)
