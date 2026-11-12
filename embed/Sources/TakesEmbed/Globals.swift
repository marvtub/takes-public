// The helper's constants. They live outside main.swift on purpose: a global in main.swift is set
// only when its top-level code runs, which never happens in the test bundle (TakesEmbedTests), so
// a test that reached one read an empty value and crashed. Globals in any other file start on
// first use (2026-11-06).
import Foundation

let segment = 8.0
let maxFrames = 450                   // one hour of footage per file
let videoExts: Set<String> = ["mov", "mp4", "m4v"]
let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
let skipDirs: Set<String> = ["storyboard", "history", "comments", "posts", "variants", "voice", "node_modules"]
let outLock = NSLock()
