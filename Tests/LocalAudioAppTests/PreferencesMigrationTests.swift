import Foundation
import XCTest
@testable import LocalAudioApp

final class PreferencesMigrationTests: XCTestCase {
    func testExistingPreferencesKeepMicrophoneFolderAndTranscriptionChoice() throws {
        let old = Data(#"{"recordingsFolder":"file:///tmp/existing-library/","inputID":"usb-mic-123","automaticallyTranscribe":false}"#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: old)
        XCTAssertEqual(preferences.recordingsFolder.path, "/tmp/existing-library")
        XCTAssertEqual(preferences.inputID, "usb-mic-123")
        XCTAssertFalse(preferences.automaticallyTranscribe)
        XCTAssertNil(preferences.quickStartCompleted)
        var completed = preferences
        completed.quickStartCompleted = true
        let reloaded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(completed))
        XCTAssertEqual(reloaded.quickStartCompleted, true)
        XCTAssertEqual(reloaded.recordingsFolder, preferences.recordingsFolder)
        XCTAssertEqual(reloaded.inputID, preferences.inputID)
    }
}
