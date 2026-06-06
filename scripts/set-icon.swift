import AppKit

// Stamp a custom Finder icon onto a file or folder (e.g. the .dmg file and the mounted volume).
// Usage: swift set-icon.swift <icon.icns> <targetPath>
let a = CommandLine.arguments
guard a.count >= 3, let img = NSImage(contentsOfFile: a[1]) else {
    FileHandle.standardError.write("usage: set-icon.swift <icon.icns> <target>\n".data(using: .utf8)!)
    exit(1)
}
let ok = NSWorkspace.shared.setIcon(img, forFile: a[2], options: [])
print(ok ? "✓ icon set: \(a[2])" : "✗ failed: \(a[2])")
exit(ok ? 0 : 1)
