import AppKit
import SwiftUI
import Testing
@testable import Takes

@MainActor
struct SoundFXTests {
    @Test func isAPublicPluginOnTheBoard() {
        #expect(Plugins.available.contains { $0.id == "sfx" })
        #expect(!PrivatePlugins.list.contains { $0.id == "sfx" })
        #expect(SoundFXPage.plugin.board == nil)
        #expect(SoundFXPage.plugin.settings != nil)
    }

    @Test func installScriptsUseTakesOwnFolderAndThePinnedEarshot() {
        let py = SoundFXSetup.dir + "/.venv/bin/python"
        let sounds = SoundFXSetup.script(.sounds, venvPython: py)
        #expect(sounds.contains("earshot/archive/925ebe56a1b755e5d354ab642bb8f344440cfa9c.tar.gz"))
        #expect(sounds.contains("--no-deps"))
        #expect(!sounds.contains("torch"))
        #expect(sounds.contains("rm -rf '\(SoundFXSetup.dir)/.venv'"))
        let design = SoundFXSetup.script(.design, venvPython: py)
        #expect(design.contains("download.pytorch.org/whl/cpu"))
        #expect(design.contains("doctor --fetch"))
        #expect(!design.contains("rm -rf"))
        #expect(SoundFXSetup.candidates.contains(py))
    }

    @Test func aFailedScriptGivesItsLastLine() {
        #expect(SoundFXSetup.run("echo 'STEP one'; echo boom >&2; exit 3") { _ in } == "The install stopped: boom")
        #expect(SoundFXSetup.run("true") { _ in } == nil)
    }

    @Test func groupsCoverTheBankWithRealCounts() throws {
        let cats = SFXGroup.all.flatMap(\.categories)
        #expect(Set(cats).count == cats.count)
        #expect(SFXGroup.of("swish").name == "Whooshes")
        #expect(SFXGroup.of("pluck").name == "More")
        let s = SFXSound(id: "pro_click/snap", category: "pro_click", dur_s: 0.05, onset_s: 0.001, peak_s: 0.004, end_s: 0.04)
        #expect(s.name == "Snap (pro)")
        #expect(s.kind == .click)
        #expect(s.duration == "0.05 s")
        #expect(SFXSound.seconds(2.85) == "2.9 s")
        let bars = s.bars(24)
        #expect(bars.count == 24 && bars.allSatisfy { $0 >= 0.08 && $0 <= 1 })
        #expect(bars == s.bars(24))
        let fit = SFXSound(id: "fit/whoosh.short/bamboo_swish", category: "fit", dur_s: 0.5, onset_s: 0, peak_s: 0.2, end_s: 0.45)
        #expect(fit.kind == .whoosh && fit.name == "Bamboo swish")
    }

    @MainActor @Test func theBankSortsByGroupAndCountsOnce() {
        let bank = SoundBank(sounds: [
            SFXSound(id: "impact/punch", category: "impact", dur_s: 1, onset_s: 0, peak_s: 0.01, end_s: 0.9),
            SFXSound(id: "swish/stick", category: "swish", dur_s: 0.4, onset_s: 0, peak_s: 0.1, end_s: 0.3),
            SFXSound(id: "impact/metal", category: "impact", dur_s: 2, onset_s: 0, peak_s: 0.01, end_s: 1.8),
        ])
        #expect(bank.groups == ["Whooshes", "Hits"])
        #expect(bank.counts == ["Whooshes": 1, "Hits": 2])
        #expect(bank.rows.map(\.id) == ["swish/stick", "impact/punch", "impact/metal"])
        #expect(bank.rows[1].key.contains("punch") && bank.rows[1].key.contains("hit"))
    }

    @Test func soundsAreMadeAheadInOneQuietProcess() {
        let py = SoundFXPlayer.aheadScript
        #expect(py.contains("os.nice(15)") && py.contains("os.replace(") && py.contains("json.load(sys.stdin)"))
        #expect(SoundFXPlayer.file("fit/hit/bamboo_tok").lastPathComponent == "fit-hit-bamboo_tok.wav")
    }

    @Test func previewsShipAndHaveARealShape() throws {
        #expect(SoundFXPreview.all.count == 6)
        for p in SoundFXPreview.all {
            let file = try #require(p.file, "missing assets/sfx for \(p.id)")
            #expect(file.pathExtension == "m4a")
            let bars = p.bars(16)
            #expect(bars.max() == 1)
        }
    }

    @Test func stepsShowAsStepNOfM() {
        let s = SoundFXSetup(python: nil, canDesign: false, running: .sounds, step: "Getting earshot…")
        #expect(s.stepLine == "Step 3 of 4 · Getting earshot")
        #expect(abs(s.progress - 0.625) < 0.001)
        let d = SoundFXSetup(python: "/x/python", canDesign: false, running: .design, step: "Getting the AI models, about 1.1 GB…")
        #expect(d.stepIndex == 2 && d.stepCount == 3)
        let script = SoundFXSetup.script(.design, venvPython: "/x/python")
        for step in SoundFXSetup.steps[.design]!.dropFirst() { #expect(script.contains("STEP " + step)) }
        let sounds = SoundFXSetup.script(.sounds, venvPython: "/x/python")
        for step in SoundFXSetup.steps[.sounds]! { #expect(sounds.contains("STEP " + step)) }
    }

    /// The page in each state, light and dark: `TAKES_SNAPSHOT=/dir ./test.sh --filter SoundFX`.
    @Test func card() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let bank = SoundBank(sounds: [
            ("fit/whoosh.short/bamboo_swish", "fit", 0.48, 0.01, 0.18, 0.45), ("impact/punch", "impact", 2.85, 0.002, 0.01, 1.4),
            ("riser/tension", "riser", 2.8, 0.05, 2.6, 2.78), ("click/snap", "click", 0.06, 0.0015, 0.0045, 0.058),
            ("logo_sting/spark", "logo_sting", 1.84, 0.003, 0.03, 1.6), ("sub_drop/808", "sub_drop", 2.05, 0.002, 0.04, 1.9),
            ("typing_key/clicky", "typing_key", 0.19, 0.001, 0.005, 0.15), ("glitch/stutter", "glitch", 0.64, 0.002, 0.02, 0.6),
            ("fit/pop/lip_pop", "fit", 0.22, 0.004, 0.02, 0.2), ("riser/shepard", "riser", 3.71, 0.05, 3.5, 3.7),
            ("impact/metal", "impact", 5.02, 0.002, 0.012, 4.2), ("logo_sting/zip_ping", "logo_sting", 1.66, 0.003, 0.3, 1.5),
            ("swish/stick", "swish", 0.42, 0.01, 0.15, 0.4), ("whoosh_big/sweep", "whoosh_big", 1.6, 0.05, 0.8, 1.5),
            ("whoosh_fast/crisp", "whoosh_fast", 0.55, 0.01, 0.2, 0.5), ("swipe/air", "swipe", 0.36, 0.01, 0.12, 0.33),
            ("whoosh_big/rumble", "whoosh_big", 2.4, 0.1, 1.2, 2.3), ("swish/cloth", "swish", 0.5, 0.01, 0.18, 0.46),
        ].map { SFXSound(id: $0.0, category: $0.1, dur_s: $0.2, onset_s: $0.3, peak_s: $0.4, end_s: $0.5) })
        let states: [(String, SoundFXSetup)] = [
            ("missing", SoundFXSetup(python: nil, canDesign: false)),
            ("installing", SoundFXSetup(python: nil, canDesign: false, running: .sounds, step: "Getting earshot…")),
            ("failed", SoundFXSetup(python: nil, canDesign: false, failed: [.sounds: "The install stopped: no network."], failedAt: 0.38)),
            ("sounds", SoundFXSetup(python: "/x/python", canDesign: false)),
            ("designing", SoundFXSetup(python: "/x/python", canDesign: false, running: .design, step: "Getting torch, about 400 MB…")),
            ("all", SoundFXSetup(python: "/x/python", canDesign: true)),
        ]
        for (state, setup) in states {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSAppearance.current = NSAppearance(named: appearance)
                let player = SoundFXPlayer(playing: setup.python == nil ? "impact/punch" : "whoosh_big/sweep")
                let v = SoundFXPage(setup: setup, bank: bank, player: player, ask: { _ in }, still: true)
                    .frame(width: 880).padding(28).background(Theme.canvas)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light)
                let r = ImageRenderer(content: v)
                r.scale = 2
                let cg = try #require(r.cgImage)
                let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: dir).appending(path: "sfx-\(state)-\(name).png"))
            }
        }
    }
}
