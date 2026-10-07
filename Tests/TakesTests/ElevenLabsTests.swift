import Foundation
import Testing
@testable import Takes

// ElevenLabs in Takes (2026-10-06): what Settings › Voices reads from the takes MCP's voices tool.

struct ElevenLabsTests {
    @Test func theAccountLineShowsPlanAndCharactersLeft() {
        #expect(ElevenLabs.accountLine(["plan": "creator", "characters_left": 95000]) == "Creator plan · \(95000.formatted()) characters left")
        #expect(ElevenLabs.accountLine([:]) == "")
    }

    @Test func ownVoicesAndLibraryVoicesBothParse() {
        let mine = ElevenLabs.voices([["id": "v1", "name": "The user PVC", "category": "professional",
                                       "labels": ["accent": "german"], "preview": "https://x.test/a.mp3"]])
        #expect(mine == [.init(id: "v1", name: "The user PVC", detail: "professional · german", preview: URL(string: "https://x.test/a.mp3"), add: nil)])
        let lib = ElevenLabs.voices([["add": "own/lib1", "name": "Brian", "accent": "american", "use_case": "narrative_story"]])
        #expect(lib.first?.id == "own/lib1")
        #expect(lib.first?.detail == "american · narrative story")
        #expect(ElevenLabs.voices([["id": "x"]]).isEmpty)
    }

    @Test func theChatAsksNameTheFileAndTheTool() {
        #expect(ElevenLabs.fixDraft("take-01-camera.mov").contains("fix_words"))
        #expect(ElevenLabs.voiceDraft("edits/a-v1.mp4").hasPrefix("Say edits/a-v1.mp4 again"))
    }
}
