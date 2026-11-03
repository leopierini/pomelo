// "Launch at login" over `SMAppService.mainApp`, behind a small protocol so the state handling is testable
// without registering a real login item.
import Foundation
import ServiceManagement

protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    /// The last failure's message. Ad-hoc-signed debug builds may be refused; the pane shows this instead of crashing.
    @Published private(set) var errorMessage: String?

    private let service: any LoginItemService

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
        status = service.status
    }

    /// Whether the toggle reads on: registered, or waiting for the user's approval in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    var needsApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        status = service.status
    }

    /// Re-reads the status, which the user can change in System Settings behind our back.
    func refresh() {
        status = service.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
