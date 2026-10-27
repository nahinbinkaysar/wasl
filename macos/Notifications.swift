import UserNotifications

/// Shows the phone's notifications in macOS Notification Center and reports when you dismiss one.
final class PhoneNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onDismiss: (String) -> Void = { _ in }

    override init() {
        super.init()
        center.delegate = self
        // customDismissAction makes macOS tell us when you clear one, so we can clear it on the phone too.
        center.setNotificationCategories([UNNotificationCategory(identifier: "phone", actions: [],
                                                                  intentIdentifiers: [], options: .customDismissAction)])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func show(_ n: [String: Any], quiet: Bool = false) {
        guard let id = n["id"] as? String else { return }
        let c = UNMutableNotificationContent()
        c.title = n["title"] as? String ?? ""
        c.subtitle = n["app"] as? String ?? ""
        c.body = n["text"] as? String ?? ""
        c.categoryIdentifier = "phone"
        c.interruptionLevel = quiet ? .passive : .active
        if !quiet { c.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// The phone's full list, sent on connect: drop what's gone, quietly add what's missing.
    func replaceAll(_ items: [[String: Any]]) {
        center.getDeliveredNotifications { delivered in
            let have = Set(delivered.map(\.request.identifier))
            let ids = Set(items.compactMap { $0["id"] as? String })
            DispatchQueue.main.async {
                self.center.removeDeliveredNotifications(withIdentifiers: Array(have.subtracting(ids)))
                for n in items where !have.contains(n["id"] as? String ?? "") { self.show(n, quiet: true) }
            }
        }
    }

    func remove(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // A menu bar app counts as "foreground", so opt in to banners; catch-up items stay in the list only.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done(n.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if r.actionIdentifier == UNNotificationDismissActionIdentifier {
            let id = r.notification.request.identifier
            DispatchQueue.main.async { self.onDismiss(id) }
        }
        done()
    }
}
