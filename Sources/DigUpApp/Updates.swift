import Foundation

/// Personal builds never connect to the upstream update feed.
final class Updates {
    var onSessionEnded: () -> Void = {}
    init(model: AppModel) {}
    func start() {}
    var automaticallyChecks: Bool { get { false } set {} }
    var canCheck: Bool { false }
    func checkNow() {}
    func checkInBackground() {}
}
