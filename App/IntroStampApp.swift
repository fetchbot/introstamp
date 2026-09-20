import SwiftUI
import AppKit

final class IntroStampAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task.detached(priority: .background) {
            SubtitleDiskCache.shared.pruneExpired()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct IntroStampApp: App {
    @NSApplicationDelegateAdaptor(IntroStampAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // Reduce tooltip show delay (default ~3 s) to 0.3 s.
        // Must be set here (before AppKit initialises the tooltip manager).
        UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")
    }

    var hasTheIntroDBKey: Bool {
        !model.theIntroDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasIntroDBKey: Bool {
        !model.introDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.appMode == .singleVideo ? "Open Video..." : "Import Segment JSON...") {
                    if model.appMode == .singleVideo {
                        model.chooseVideoFile()
                    } else {
                        model.chooseReviewImportFiles()
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Segments") {
                Section("Set Draft Boundary") {
                    Button("Set Intro Start") { model.setDraftStart(.intro) }
                        .keyboardShortcut("i", modifiers: [])
                    Button("Set Intro End") { model.setDraftEnd(.intro) }
                        .keyboardShortcut("I", modifiers: .shift)

                    Button("Set Recap Start") { model.setDraftStart(.recap) }
                        .keyboardShortcut("r", modifiers: [])
                    Button("Set Recap End") { model.setDraftEnd(.recap) }
                        .keyboardShortcut("R", modifiers: .shift)

                    Button("Set Credits Start") { model.setDraftStart(.credits) }
                        .keyboardShortcut("c", modifiers: [])
                    Button("Set Credits End") { model.setDraftEnd(.credits) }
                        .keyboardShortcut("C", modifiers: .shift)

                    Button("Set Preview Start") { model.setDraftStart(.preview) }
                        .keyboardShortcut("p", modifiers: [])
                    Button("Set Preview End") { model.setDraftEnd(.preview) }
                        .keyboardShortcut("P", modifiers: .shift)
                }

                Divider()

                Section("Jump To Segment Boundary") {
                    Button("Jump To Next Intro Start") { model.jumpToNextStart(.intro) }
                        .keyboardShortcut("i", modifiers: .command)
                    Button("Jump To Next Intro End") { model.jumpToNextEnd(.intro) }
                        .keyboardShortcut("I", modifiers: [.command, .shift])

                    Button("Jump To Next Recap Start") { model.jumpToNextStart(.recap) }
                        .keyboardShortcut("r", modifiers: .command)
                    Button("Jump To Next Recap End") { model.jumpToNextEnd(.recap) }
                        .keyboardShortcut("R", modifiers: [.command, .shift])

                    Button("Jump To Next Credits Start") { model.jumpToNextStart(.credits) }
                        .keyboardShortcut("c", modifiers: .command)
                    Button("Jump To Next Credits End") { model.jumpToNextEnd(.credits) }
                        .keyboardShortcut("C", modifiers: [.command, .shift])

                    Button("Jump To Next Preview Start") { model.jumpToNextStart(.preview) }
                        .keyboardShortcut("p", modifiers: .command)
                    Button("Jump To Next Preview End") { model.jumpToNextEnd(.preview) }
                        .keyboardShortcut("P", modifiers: [.command, .shift])
                }

                Divider()

                Section("Toggle No Segment") {
                    Button("Toggle No Intro") { model.toggleNoSegment(.intro) }
                        .keyboardShortcut("i", modifiers: .option)
                    Button("Toggle No Recap") { model.toggleNoSegment(.recap) }
                        .keyboardShortcut("r", modifiers: .option)
                    Button("Toggle No Credits") { model.toggleNoSegment(.credits) }
                        .keyboardShortcut("c", modifiers: .option)
                    Button("Toggle No Preview") { model.toggleNoSegment(.preview) }
                        .keyboardShortcut("p", modifiers: .option)
                }

                Divider()

                Button("Move Nearest Boundary To Playhead") {
                    model.moveNearestSegmentEndToPlayhead()
                }
                .keyboardShortcut(",", modifiers: [])
            }

            CommandMenu("Navigation") {
                Button("Jump To Previous Scene") { model.jumpToPreviousScene() }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("Jump To Next Scene") { model.jumpToNextScene() }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)

                Divider()

                Button("Nudge Nearest Boundary Backward 1 Frame") {
                    model.nudgeNearestBoundary(by: -model.frameDurationMs)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("Nudge Nearest Boundary Forward 1 Frame") {
                    model.nudgeNearestBoundary(by: model.frameDurationMs)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Button("Nudge Nearest Boundary Backward 1 Second") {
                    model.nudgeNearestBoundary(by: -1000)
                }
                .keyboardShortcut(.leftArrow, modifiers: .option)

                Button("Nudge Nearest Boundary Forward 1 Second") {
                    model.nudgeNearestBoundary(by: 1000)
                }
                .keyboardShortcut(.rightArrow, modifiers: .option)

                Divider()

                Button("Open Next Episode") {
                    model.openNextEpisode()
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])
                .disabled(model.appMode != .singleVideo)

                Divider()

                Button("Clear Input Focus") {
                    model.clearInputFocus()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            if hasTheIntroDBKey || hasIntroDBKey {
                CommandMenu("Tools") {
                    if hasTheIntroDBKey {
                        Button("Backup TheIntroDB Submissions") {
                            model.backupServicePending = "theintrodb"
                        }
                    }
                    
                    if hasIntroDBKey {
                        Button("Backup IntroDB.app Submissions") {
                            model.backupServicePending = "introdb"
                        }
                    }
                }
            }
        }
    }
}
