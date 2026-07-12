import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var session: AnyObject?
    func restoreSession() async {}
}
