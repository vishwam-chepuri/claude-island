import Foundation
import ServiceManagement

/// The only place `SMAppService` is touched.
///
/// `SMAppService.mainApp` registers the *running bundle*, so this is
/// meaningless outside a `.app` — from `swift run` there is no bundle to
/// register and `register()` fails. `isAvailable` gates on that rather than
/// letting the menu offer something that cannot work.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// Throws whatever `SMAppService` throws. Callers surface it rather than
    /// swallow it: a login item that silently did not register is the one
    /// failure mode worth an alert.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
