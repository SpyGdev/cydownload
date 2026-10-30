# CyDownload

macOS Cydia repository browser, written in Swift and SwiftUI.

Open a saved repo, browse packages by section, and download `.deb` files. Repositories are stored in `~/Library/Application Support/cydownload/repos.ini`. Dark mode is a checkbox in the main window and is remembered between launches.

## Build and run

Open `CyDownload.xcodeproj` in Xcode and press Run.

From the command line:

```
xcodebuild -project CyDownload.xcodeproj -scheme CyDownload -configuration Debug build
```
