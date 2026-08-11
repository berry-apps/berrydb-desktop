import AppKit

let path = "/Users/tan/idea/berrydb/deploy/AppIcon.icns"
if let image = NSImage(contentsOfFile: path) {
    print("SUCCESS: loaded icon of size \(image.size)")
} else {
    print("FAILED to load icon at \(path)")
}
