.PHONY: build test release app clean

build:
	swift build

test:
	swift test

release:
	swift build -c release

app:
	cd App && xcodegen generate && xcodebuild -project S3InventoryVisualizer.xcodeproj -scheme "S3 Inventory Visualizer" -configuration Release -derivedDataPath build build | tail -20
	@echo "App at App/build/Build/Products/Release/S3 Inventory Visualizer.app"

clean:
	rm -rf .build App/build App/S3InventoryVisualizer.xcodeproj
