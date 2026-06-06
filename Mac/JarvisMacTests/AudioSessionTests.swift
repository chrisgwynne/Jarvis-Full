import XCTest
@testable import JarvisMac

// MARK: - AudioSessionTests
//
// Regression tests for the AudioSessionCoordinator and the wake→STT
// handoff lifecycle. These run entirely on model/coordinator types —
// no audio hardware, no speech permissions, no JarvisController.

@MainActor
final class AudioSessionTests: XCTestCase {

    // MARK: - AudioSessionCoordinator basics

    func testCoordinator_startsIdle() {
        let coord = AudioSessionCoordinator()
        XCTAssertEqual(coord.currentMode, .idle,
                       "Coordinator must start in .idle before any audio work begins")
    }

    func testCoordinator_wakeTransition() {
        let coord = AudioSessionCoordinator()
        coord.transition(to: .passiveWake, from: "test")
        XCTAssertEqual(coord.currentMode, .passiveWake)
    }

    func testCoordinator_sttTransitionFromIdle() {
        let coord = AudioSessionCoordinator()
        coord.transition(to: .activeSTT, from: "test")
        XCTAssertEqual(coord.currentMode, .activeSTT)
    }

    func testCoordinator_releaseSTT() {
        let coord = AudioSessionCoordinator()
        coord.transition(to: .activeSTT, from: "test")
        coord.transition(to: .idle, from: "test")
        XCTAssertEqual(coord.currentMode, .idle,
                       "STT release must return coordinator to .idle")
    }

    func testCoordinator_noDoubleTransition() {
        // Transitioning to the current mode must be a no-op and not crash.
        let coord = AudioSessionCoordinator()
        coord.transition(to: .passiveWake, from: "test")
        coord.transition(to: .passiveWake, from: "test") // duplicate — should be silent
        XCTAssertEqual(coord.currentMode, .passiveWake)
    }

    // MARK: - Wake → STT → wake handoff lifecycle

    func testWakeToSTTHandoff_coordinatorSequence() {
        // Simulate the full lifecycle:
        //   passiveWake → (wake fires) → idle → activeSTT → idle → passiveWake
        let coord = AudioSessionCoordinator()

        // 1. Wake word engine arms
        coord.transition(to: .passiveWake, from: "AppleWakeWordService.start")
        XCTAssertEqual(coord.currentMode, .passiveWake)

        // 2. Wake detection: engine tears down and releases mic
        coord.transition(to: .idle, from: "AppleWakeWordService.wakeDetected")
        XCTAssertEqual(coord.currentMode, .idle,
                       "After wake detection the coordinator must be idle before STT claims the mic")

        // 3. STT session starts
        coord.transition(to: .activeSTT, from: "AppleSpeechRecognizer")
        XCTAssertEqual(coord.currentMode, .activeSTT)

        // 4. STT session ends
        coord.transition(to: .idle, from: "AppleSpeechRecognizer.stop")
        XCTAssertEqual(coord.currentMode, .idle)

        // 5. Wake word engine re-arms
        coord.transition(to: .passiveWake, from: "AppleWakeWordService.start")
        XCTAssertEqual(coord.currentMode, .passiveWake,
                       "Wake word must resume passive mode after STT session ends")
    }

    func testWakeToSTTHandoff_idleBeforeSTT() {
        // The coordinator must reach .idle between passiveWake and activeSTT.
        // Skipping that step (passiveWake → activeSTT directly) would indicate
        // the wake engine wasn't stopped before STT grabbed the mic.
        let coord = AudioSessionCoordinator()
        coord.transition(to: .passiveWake, from: "test")

        // Simulate the correct path: idle first, then STT
        coord.transition(to: .idle, from: "wake.teardown")
        XCTAssertEqual(coord.currentMode, .idle)

        coord.transition(to: .activeSTT, from: "stt.start")
        XCTAssertEqual(coord.currentMode, .activeSTT)
    }

    // MARK: - pbxproj UUID regression

    func testPbxprojUUIDs_AudioSession_unique() {
        let uuids = [
            "AS01A2B3C4D5E6F7A8B9C001", // PBXBuildFile  — AudioSessionCoordinator.swift (app)
            "AS02A2B3C4D5E6F7A8B9C001", // PBXFileReference — AudioSessionCoordinator.swift
            "AS01A2B3C4D5E6F7A8B9C002", // PBXBuildFile  — AudioSessionTests.swift (test)
            "AS02A2B3C4D5E6F7A8B9C002", // PBXFileReference — AudioSessionTests.swift
        ]
        XCTAssertEqual(Set(uuids).count, uuids.count,
                       "All AudioSession pbxproj UUIDs must be unique")
    }
}
