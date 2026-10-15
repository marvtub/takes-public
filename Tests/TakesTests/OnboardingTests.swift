import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

extension ChatRunTests {
    // The welcome as a new user goes through it (2026-10-06): when it shows, the pages, and what the
    // two buttons on the last page make. A fake claude stands in for the chat. In ChatRunTests: it
    // sets the one fake claude, so it must not run beside those tests.
    @MainActor @Suite(.serialized) struct OnboardingTests {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "takes-welcome-\(UUID().uuidString)")
        let flow = Onboarding.shared
        let setup = Setup.shared

        func fresh() throws -> AppModel {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            UserDefaults.standard.removeObject(forKey: Onboarding.doneKey)
            flow.shown = false; flow.page = 0
            let app = AppModel()
            app.library.setRoot(root)
            return app
        }

        func cleanup() {
            UserDefaults.standard.removeObject(forKey: Onboarding.doneKey)
            flow.shown = false
            ClaudeChat.claudeOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        func ready(ffmpeg: Setup.Status = .ok) { setup.agent = .ok; setup.signedIn = .ok; setup.ffmpeg = ffmpeg; setup.devTools = .ok }

        @Test func showsOnceToANewLibraryOnly() throws {
            defer { cleanup() }
            let app = try fresh()
            flow.startIfNew(app.library)
            #expect(flow.shown && flow.page == 0)
            flow.finish()
            #expect(!flow.shown)
            flow.startIfNew(app.library)
            #expect(!flow.shown, "closed once, it stays closed")

            // Someone who has used Takes already never sees it, and it is marked done for good.
            UserDefaults.standard.removeObject(forKey: Onboarding.doneKey)
            _ = app.library.createProject("Videos")
            flow.startIfNew(app.library)
            #expect(!flow.shown)
            #expect(UserDefaults.standard.bool(forKey: Onboarding.doneKey))
        }

        /// Skip, Esc and "Look around first" all end in finish(): from any page it closes, and stays
        /// closed at the next launch.
        @Test func skipClosesFromEveryPageForGood() throws {
            defer { cleanup() }
            let app = try fresh()
            for page in 0..<Onboarding.pages {
                UserDefaults.standard.removeObject(forKey: Onboarding.doneKey)
                flow.show(); flow.go(page)
                flow.finish()
                #expect(!flow.shown, "page \(page)")
                flow.startIfNew(app.library)
                #expect(!flow.shown && UserDefaults.standard.bool(forKey: Onboarding.doneKey), "page \(page)")
            }
        }

        /// 2026-10-15 (Product Hunt, newest macOS): Skip "did nothing" and after Write my script the
        /// welcome would not go, so the app had to be quit. A welcome on its way out kept taking every
        /// click until its exit animation ended; an exit that never ends left the window dead.
        @Test func aClosingWelcomeLetsClicksThrough() async throws {
            defer { cleanup() }
            let app = try fresh()
            final class Taps { var n = 0 }
            let taps = Taps()
            let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 960, height: 700), styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ZStack {
                Button { taps.n += 1 } label: { Color.gray.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                OnboardingLayer()
            }.environment(app))
            w.orderFrontRegardless()
            defer { w.orderOut(nil) }
            func click() {
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    w.sendEvent(NSEvent.mouseEvent(with: t, location: NSPoint(x: 30, y: 30), modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseDown ? 1 : 0)!)
                }
            }
            flow.show()
            try await Task.sleep(for: .milliseconds(600))
            click()
            try await Task.sleep(for: .milliseconds(50))
            #expect(taps.n == 0, "the open welcome keeps the window out of reach")
            flow.finish()
            try await Task.sleep(for: .milliseconds(50))
            click()
            try await Task.sleep(for: .milliseconds(50))
            #expect(taps.n == 1, "the window answers at once, before the fade ends")
        }

        /// The shade over the window while the notch's tour runs: its Skip must not depend on the
        /// notch panel, which may be off screen (another Space, full screen).
        @Test func skippingTheNotchTourClearsTheShade() {
            let d = UserDefaults.standard
            defer { d.removeObject(forKey: NotchView.introKey) }
            d.set(0, forKey: NotchView.introKey)
            let app = AppModel()
            app.notchTour = true
            NotchTourShade.skip(app)
            #expect(!app.notchTour)
            #expect(d.integer(forKey: NotchView.introKey) == NotchView.intro.count)
        }

        @Test func pagesStopAtBothEnds() throws {
            defer { cleanup() }
            _ = try fresh()
            flow.show()
            flow.go(-1); #expect(flow.page == 0)
            flow.go(1); #expect(flow.page == 1 && flow.forward)
            flow.go(2); flow.go(3); #expect(flow.page == 2)
            flow.go(1); #expect(flow.page == 1 && !flow.forward)
            flow.show(); #expect(flow.page == 0, "the menu item starts it from the first page")
        }

        @Test func writingNeedsClaudeButNotFFmpeg() {
            ready(ffmpeg: .missing)
            #expect(Onboarding.canWrite)
            setup.signedIn = .missing
            #expect(!Onboarding.canWrite)
            setup.agent = .missing; setup.signedIn = .ok
            #expect(!Onboarding.canWrite)
        }

        @Test func writeMyScriptOpensASessionOnRecordAndAsksTheChat() async throws {
            defer { cleanup() }
            let app = try fresh()
            ready()
            let fake = root.appending(path: "claude")
            try """
            #!/bin/bash
            cat > /dev/null
            echo '{"type":"system","subtype":"init"}'
            echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Your script is in the session."}]}}'
            echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
            """.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            // claudeOverride is one global that ChatRunTests and ZBenchStream also set while this runs,
            // so check what the chat sent, not what this fake received.
            ClaudeChat.claudeOverride = fake.path
            SessionMode.set(.post)
            flow.show(); flow.go(2)

            flow.write("   ", app: app)
            #expect(flow.shown && app.library.current == nil, "an empty idea does nothing")

            flow.write("  How I plan my week ", app: app)
            #expect(!flow.shown)
            #expect(UserDefaults.standard.bool(forKey: Onboarding.doneKey))
            #expect(app.library.projects.map(\.name) == ["Inbox"])
            let doc = try #require(app.library.current)
            #expect(app.library.sessions.map(\.url) == [doc.url])
            #expect(doc.meta.title == "How I plan my week" && doc.meta.named, "named after the idea, so it is not renamed under the chat")
            #expect(doc.url.lastPathComponent.hasSuffix("how-i-plan-my-week"))
            #expect(UserDefaults.standard.string(forKey: "rightTab") == SessionMode.write.rawValue, "the script shows next to the chat")
            #expect(app.chats.open && app.chats.docked)
            let chat = app.chats.chat(doc.url)
            #expect(chat.messages.first { $0.role == .user }?.text == Onboarding.ask("How I plan my week"))
            let end = Date().addingTimeInterval(10)
            while chat.running && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
            #expect(!chat.running)
            #expect(chat.messages.contains { $0.role == .claude && $0.text == "Your script is in the session." })
        }

        @Test func writeWaitsForSetup() throws {
            defer { cleanup() }
            let app = try fresh()
            setup.agent = .missing; setup.signedIn = .missing
            flow.show(); flow.go(2)
            flow.write("A tool I use every day", app: app)
            #expect(flow.shown && app.library.current == nil)
        }

        @Test func recordWithoutAScriptOpensAnEmptySessionOnRecord() throws {
            defer { cleanup() }
            let app = try fresh()
            setup.agent = .missing  // recording works before setup
            SessionMode.set(.post)
            flow.show(); flow.go(2)
            flow.recordNow(app: app)
            #expect(!flow.shown)
            #expect(app.library.current != nil)
            #expect(UserDefaults.standard.string(forKey: "rightTab") == SessionMode.record.rawValue)
            #expect(!app.chats.chat(app.library.current!.url).messages.contains { $0.role == .user })
        }
    }
}
