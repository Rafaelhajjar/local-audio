import Foundation
import XCTest
import LocalAudioCore
@testable import LocalAudioApp

final class PreferencesMigrationTests: XCTestCase {
    func testExistingPreferencesKeepMicrophoneFolderAndTranscriptionChoice() throws {
        let old = Data(#"{"recordingsFolder":"file:///tmp/existing-library/","inputID":"usb-mic-123","automaticallyTranscribe":false}"#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: old)
        XCTAssertEqual(preferences.recordingsFolder.path, "/tmp/existing-library")
        XCTAssertEqual(preferences.inputID, "usb-mic-123")
        XCTAssertFalse(preferences.automaticallyTranscribe)
        XCTAssertNil(preferences.quickStartCompleted)
        XCTAssertNil(preferences.microphonePolicy)
        XCTAssertNil(preferences.retention)
        var completed = preferences
        completed.quickStartCompleted = true
        let reloaded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(completed))
        XCTAssertEqual(reloaded.quickStartCompleted, true)
        XCTAssertEqual(reloaded.recordingsFolder, preferences.recordingsFolder)
        XCTAssertEqual(reloaded.inputID, preferences.inputID)
    }
    func testMicrophoneBlockApprovedListAndOptInRetentionSurviveRelaunch() throws {
        var preferences = AppPreferences(recordingsFolder: URL(fileURLWithPath: "/tmp/library"))
        var policy = MicrophonePolicy(); policy.mode = .approved; policy.allowMacMicrophone = false
        policy.approved = (1...3).map { MicrophoneChoice(id: "usb-\($0)", name: "Mic \($0)") }
        preferences.microphonePolicy = policy
        preferences.retention = AudioRetention(days: 7, enabledAt: Date(timeIntervalSince1970: 1000))
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.microphonePolicy, policy)
        XCTAssertEqual(decoded.retention, preferences.retention)
    }

}
