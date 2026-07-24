import Foundation
import Testing
@testable import AccioComputerUseKit

@Suite(.serialized)
struct BackgroundModePreferenceTests {
private func withRestoredBackgroundPreference(_ body: () -> Void) {
    let defaults = UserDefaults.standard
    let originalPreference = defaults.object(forKey: preferBackgroundModeDefaultsKey)
    let originalMigration = defaults.object(forKey: preferBackgroundModeDefaultMigrationKey)
    defer {
        if let originalPreference {
            defaults.set(originalPreference, forKey: preferBackgroundModeDefaultsKey)
        } else {
            defaults.removeObject(forKey: preferBackgroundModeDefaultsKey)
        }

        if let originalMigration {
            defaults.set(originalMigration, forKey: preferBackgroundModeDefaultMigrationKey)
        } else {
            defaults.removeObject(forKey: preferBackgroundModeDefaultMigrationKey)
        }
    }

    body()
}

@Test func preferBackgroundOperationsDefaultsToFalseWhenUnset() {
    withRestoredBackgroundPreference {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: preferBackgroundModeDefaultsKey)
        defaults.removeObject(forKey: preferBackgroundModeDefaultMigrationKey)
        registerComputerUseDefaults()

        #expect(preferBackgroundOperations == false)
    }
}

@Test func preferBackgroundOperationsMigratesOldStoredTrueToFalse() {
    withRestoredBackgroundPreference {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: preferBackgroundModeDefaultsKey)
        defaults.removeObject(forKey: preferBackgroundModeDefaultMigrationKey)

        registerComputerUseDefaults()

        #expect(preferBackgroundOperations == false)
        #expect(defaults.bool(forKey: preferBackgroundModeDefaultMigrationKey) == true)
    }
}

@Test func preferBackgroundOperationsFollowsUserDefaults() {
    withRestoredBackgroundPreference {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: preferBackgroundModeDefaultMigrationKey)

        defaults.set(false, forKey: preferBackgroundModeDefaultsKey)
        #expect(preferBackgroundOperations == false)

        defaults.set(true, forKey: preferBackgroundModeDefaultsKey)
        #expect(preferBackgroundOperations == true)
    }
}

@Test func globalPointerFallbacksAreSuppressedWhenBackgroundPreferred() {
    withRestoredBackgroundPreference {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: preferBackgroundModeDefaultMigrationKey)

        let environment = ["ACCIO_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1"]

        defaults.set(false, forKey: preferBackgroundModeDefaultsKey)
        #expect(globalPointerFallbacksEnabled(environment: environment) == true)

        defaults.set(true, forKey: preferBackgroundModeDefaultsKey)
        #expect(globalPointerFallbacksEnabled(environment: environment) == false)
    }
}
}
