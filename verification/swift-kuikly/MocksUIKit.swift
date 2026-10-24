import Foundation
public enum UIApplicationState { case active, inactive, background }
public final class UIApplication {
    public static let shared = UIApplication()
    public static let didBecomeActiveNotification = Notification.Name("UIApplicationDidBecomeActiveNotification")
    public var applicationState = UIApplicationState.active
}
