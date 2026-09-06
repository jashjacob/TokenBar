import AppKit
import Darwin
import ObjectiveC.runtime

@objc private protocol TouchBarPresenting {
    @objc(presentSystemModalTouchBar:systemTrayItemIdentifier:)
    static func presentSystemModalTouchBar(_ touchBar: NSTouchBar, systemTrayItemIdentifier: NSTouchBarItem.Identifier)

    @objc(dismissSystemModalTouchBar:)
    static func dismissSystemModalTouchBar(_ touchBar: NSTouchBar)

    @objc(minimizeSystemModalTouchBar:)
    static func minimizeSystemModalTouchBar(_ touchBar: NSTouchBar)
}

@objc private protocol TouchBarItemTray {
    @objc(addSystemTrayItem:)
    static func addSystemTrayItem(_ item: NSTouchBarItem)

    @objc(removeSystemTrayItem:)
    static func removeSystemTrayItem(_ item: NSTouchBarItem)
}

/// Undocumented Control Strip / system-modal Touch Bar hooks.
/// Public NSTouchBar only appears while this app is focused, which is useless
/// for a quota strip. These selectors still resolve on this Mac (macOS 26).
enum PrivateTouchBar {
    static let stripIdentifier = NSTouchBarItem.Identifier("com.jashjacob.TokenBar.strip")
    static var onExternalCollapse: (() -> Void)?

    private static var hooked = false
    private static var suppressCollapseNotice = false
    private static var originalMinimize: IMP?
    private static var originalDismiss: IMP?

    static func installCollapseHook() {
        guard !hooked else { return }
        hooked = true
        originalMinimize = wrapClassMethod(
            NSTouchBar.self,
            selector: NSSelectorFromString("minimizeSystemModalTouchBar:")
        ) { bar in
            callOriginal(originalMinimize, selector: NSSelectorFromString("minimizeSystemModalTouchBar:"), bar: bar)
            noteExternalCollapse()
        }
        originalDismiss = wrapClassMethod(
            NSTouchBar.self,
            selector: NSSelectorFromString("dismissSystemModalTouchBar:")
        ) { bar in
            callOriginal(originalDismiss, selector: NSSelectorFromString("dismissSystemModalTouchBar:"), bar: bar)
            noteExternalCollapse()
        }
    }

    static func noteExternalCollapse() {
        guard !suppressCollapseNotice else { return }
        DispatchQueue.main.async { onExternalCollapse?() }
    }

    static func present(_ touchBar: NSTouchBar) {
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        guard NSTouchBar.responds(to: sel) else {
            Log.line("presentSystemModalTouchBar unavailable")
            return
        }
        let cls = unsafeBitCast(NSTouchBar.self, to: TouchBarPresenting.Type.self)
        cls.presentSystemModalTouchBar(touchBar, systemTrayItemIdentifier: stripIdentifier)
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        let sel = NSSelectorFromString("dismissSystemModalTouchBar:")
        guard NSTouchBar.responds(to: sel) else { return }
        suppressCollapseNotice = true
        defer { suppressCollapseNotice = false }
        let cls = unsafeBitCast(NSTouchBar.self, to: TouchBarPresenting.Type.self)
        cls.dismissSystemModalTouchBar(touchBar)
    }

    static func minimize(_ touchBar: NSTouchBar) {
        let sel = NSSelectorFromString("minimizeSystemModalTouchBar:")
        guard NSTouchBar.responds(to: sel) else { return }
        suppressCollapseNotice = true
        defer { suppressCollapseNotice = false }
        let cls = unsafeBitCast(NSTouchBar.self, to: TouchBarPresenting.Type.self)
        cls.minimizeSystemModalTouchBar(touchBar)
    }

    static func addStripItem(_ item: NSTouchBarItem) {
        let sel = NSSelectorFromString("addSystemTrayItem:")
        guard NSTouchBarItem.responds(to: sel) else {
            Log.line("addSystemTrayItem unavailable")
            return
        }
        let cls = unsafeBitCast(NSTouchBarItem.self, to: TouchBarItemTray.Type.self)
        cls.addSystemTrayItem(item)
        DFRElementSetControlStripPresenceForIdentifier(stripIdentifier, true)
    }

    static func removeStripItem(_ item: NSTouchBarItem) {
        DFRElementSetControlStripPresenceForIdentifier(stripIdentifier, false)
        let sel = NSSelectorFromString("removeSystemTrayItem:")
        guard NSTouchBarItem.responds(to: sel) else { return }
        let cls = unsafeBitCast(NSTouchBarItem.self, to: TouchBarItemTray.Type.self)
        cls.removeSystemTrayItem(item)
    }

    private static func DFRElementSetControlStripPresenceForIdentifier(
        _ identifier: NSTouchBarItem.Identifier,
        _ present: Bool
    ) {
        typealias Fn = @convention(c) (CFString, Bool) -> Void
        guard let fn = load("DFRElementSetControlStripPresenceForIdentifier", as: Fn.self) else { return }
        fn(identifier.rawValue as CFString, present)
    }

    private static func DFRSystemModalShowsCloseBoxWhenFrontMost(_ show: Bool) {
        typealias Fn = @convention(c) (Bool) -> Void
        guard let fn = load("DFRSystemModalShowsCloseBoxWhenFrontMost", as: Fn.self) else { return }
        fn(show)
    }

    private static func load<T>(_ name: String, as: T.Type) -> T? {
        let paths = [
            "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
            "/System/Library/PrivateFrameworks/DFRFoundation.framework/Versions/A/DFRFoundation",
        ]
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW), let sym = dlsym(handle, name) {
                return unsafeBitCast(sym, to: T.self)
            }
        }
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
            return unsafeBitCast(sym, to: T.self)
        }
        Log.line("private API missing: \(name)")
        return nil
    }

    private static func wrapClassMethod(
        _ type: AnyClass,
        selector: Selector,
        body: @escaping (NSTouchBar) -> Void
    ) -> IMP? {
        guard let method = class_getClassMethod(type, selector) else {
            Log.line("collapse hook missing \(NSStringFromSelector(selector))")
            return nil
        }
        let previous = method_getImplementation(method)
        let block: @convention(block) (AnyObject, NSTouchBar) -> Void = { _, bar in
            body(bar)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return previous
    }

    private static func callOriginal(_ imp: IMP?, selector: Selector, bar: NSTouchBar) {
        guard let imp else { return }
        typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
        unsafeBitCast(imp, to: Fn.self)(NSTouchBar.self, selector, bar)
    }
}
