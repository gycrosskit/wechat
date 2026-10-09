import Foundation
public typealias KuiklyRenderCallback = (Any?) -> Void
open class KRBaseModule: NSObject {
    public var hr_rootView: NSObject? = NSObject()
    open class func moduleName() -> String { "" }
    open func hrv_call(withMethod method: String, params: Any?, callback: KuiklyRenderCallback?) -> Any? { nil }
    open func invalidate() {}
    // Actual TDFBaseModule dealloc also invokes invalidate.
    deinit { invalidate() }
}

public enum KuiklyRenderThreadManager {
    public static var paused = false
    private static var pending = [() -> Void]()
    public static func performOnContextQueue(_ action: @escaping () -> Void) { if paused { pending.append(action) } else { action() } }
    public static func drain() { let actions = pending; pending.removeAll(); actions.forEach { $0() } }
}
