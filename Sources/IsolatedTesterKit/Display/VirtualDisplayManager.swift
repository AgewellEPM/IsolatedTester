import CoreGraphics
import Foundation
import ObjectiveC
import ScreenCaptureKit

/// Manages creation and lifecycle of virtual displays.
/// Uses CGVirtualDisplay (private API, accessed via ObjC runtime) to create real isolated displays.
/// Falls back to main display when virtual display creation isn't available.
public final class VirtualDisplayManager: @unchecked Sendable {

    public struct DisplayConfig: Sendable {
        public let width: Int
        public let height: Int
        public let ppi: Int
        public let name: String

        public init(width: Int = 1920, height: Int = 1080, ppi: Int = 144, name: String = "IsolatedTest") {
            self.width = width
            self.height = height
            self.ppi = ppi
            self.name = name
        }
    }

    public struct ManagedDisplay: Sendable {
        public let displayID: CGDirectDisplayID
        public let config: DisplayConfig
        public let createdAt: Date
        public let isVirtual: Bool

        public var description: String {
            let tag = isVirtual ? "virtual" : "physical"
            return "\(config.name) [\(displayID)] — \(config.width)x\(config.height) (\(tag))"
        }
    }

    private var displays: [CGDirectDisplayID: ManagedDisplay] = [:]
    // Must keep strong references to ObjC virtual display objects or they get deallocated
    private var virtualDisplayObjects: [CGDirectDisplayID: AnyObject] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Create Virtual Display

    /// Creates a virtual display using CGVirtualDisplay (private API via ObjC runtime).
    /// This creates a real isolated display that doesn't interfere with the user's screens.
    public func createDisplay(config: DisplayConfig = .init()) throws -> ManagedDisplay {
        // Check if CGVirtualDisplay is available at runtime
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor"),
              let displayClass = NSClassFromString("CGVirtualDisplay"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode") else {
            throw DisplayError.creationFailed(
                "CGVirtualDisplay not available on this system. " +
                "Requires macOS 12+ with CoreGraphics virtual display support. " +
                "Falling back to main display — use startOnMainDisplay() instead."
            )
        }

        // Create descriptor — use a safe cast so we throw a descriptive error instead of
        // crashing with EXC_BAD_INSTRUCTION if CGVirtualDisplayDescriptor ever stops
        // being an NSObject subclass (e.g. on a future OS version).
        guard let descriptorType = descriptorClass as? NSObject.Type else {
            throw DisplayError.creationFailed("CGVirtualDisplayDescriptor is not an NSObject subclass")
        }
        let descriptor = descriptorType.init()

        // Set properties via KVC (since we don't have headers)
        descriptor.setValue(config.name, forKey: "name")
        descriptor.setValue(config.width, forKey: "maxPixelsWide")
        descriptor.setValue(config.height, forKey: "maxPixelsHigh")
        // Fixed 27" physical size — critical: do NOT compute from resolution
        // This prevents WindowServer from rejecting the display due to unrealistic pixel density
        descriptor.setValue(CGSize(width: 597, height: 336), forKey: "sizeInMillimeters")
        descriptor.setValue(UInt32(0xF0F0), forKey: "vendorID")
        descriptor.setValue(UInt32(0x0001), forKey: "productID")
        descriptor.setValue(arc4random(), forKey: "serialNum")

        // Set dispatch queue via selector (the property is named dispatchQueue but setter is setDispatchQueue:)
        let queue = DispatchQueue(label: "com.isolatedtester.virtualdisplay")
        let setQueueSel = NSSelectorFromString("setDispatchQueue:")
        if descriptor.responds(to: setQueueSel) {
            descriptor.perform(setQueueSel, with: queue)
        }

        // Create the virtual display via alloc + initWithDescriptor:
        // IMPORTANT: must use alloc/init pattern, NOT init() then perform(initSel)
        // because perform() on init methods double-initializes and corrupts memory.
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithDescriptor:")

        guard let allocated = (displayClass as AnyObject).perform(allocSel)?.takeUnretainedValue(),
              let initialized = allocated.perform(initSel, with: descriptor)?.takeRetainedValue() as? NSObject else {
            throw DisplayError.creationFailed(
                "CGVirtualDisplay initWithDescriptor: returned nil. " +
                "This usually means the com.apple.VirtualDisplay entitlement is missing. " +
                "For development, use startOnMainDisplay() or add the entitlement to your app."
            )
        }

        return try configureAndRegister(initialized, settingsClass: settingsClass, modeClass: modeClass, config: config)
    }

    private func configureAndRegister(
        _ displayObj: NSObject,
        settingsClass: AnyClass,
        modeClass: AnyClass,
        config: DisplayConfig
    ) throws -> ManagedDisplay {
        // Create display mode via initWithWidth:height:refreshRate:
        // Properties are readonly, so KVC won't work — must use the proper init selector.
        let modeInitSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let modeAllocSel = NSSelectorFromString("alloc")

        // NSInvocation is not available in Swift, so use the KVC-settable init() as fallback
        // and set via the constructor if available. For CGVirtualDisplayMode, the init args
        // are primitive types which perform() can't pass, so we use an NSInvocation workaround.
        let mode: NSObject
        let allocatedMode = (modeClass as AnyObject).perform(modeAllocSel)?.takeUnretainedValue() as? NSObject
        if let am = allocatedMode, am.responds(to: modeInitSel) {
            // Use objc_msgSend for primitive parameters that perform() can't handle
            typealias ModeInitFn = @convention(c) (AnyObject, Selector, Int, Int, Double) -> AnyObject?
            let fn = unsafeBitCast(class_getMethodImplementation(modeClass, modeInitSel), to: ModeInitFn.self)
            if let result = fn(am, modeInitSel, config.width, config.height, 60.0) as? NSObject {
                mode = result
            } else {
                // Fallback: use default init and try KVC — safe cast to avoid crash
                // if CGVirtualDisplayMode is not an NSObject subclass.
                guard let modeType = modeClass as? NSObject.Type else {
                    throw DisplayError.creationFailed("CGVirtualDisplayMode is not an NSObject subclass")
                }
                mode = modeType.init()
                mode.setValue(config.width, forKey: "width")
                mode.setValue(config.height, forKey: "height")
                mode.setValue(60.0, forKey: "refreshRate")
            }
        } else {
            // Safe cast for the else-branch fallback init as well.
            guard let modeType = modeClass as? NSObject.Type else {
                throw DisplayError.creationFailed("CGVirtualDisplayMode is not an NSObject subclass")
            }
            mode = modeType.init()
            mode.setValue(config.width, forKey: "width")
            mode.setValue(config.height, forKey: "height")
            mode.setValue(60.0, forKey: "refreshRate")
        }

        // Create settings — safe cast to avoid crash if the class is not an NSObject subclass.
        guard let settingsType = settingsClass as? NSObject.Type else {
            throw DisplayError.creationFailed("CGVirtualDisplaySettings is not an NSObject subclass")
        }
        let settings = settingsType.init()
        settings.setValue(UInt32(config.ppi > 100 ? 2 : 1), forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")

        // Apply settings to display
        let applySel = NSSelectorFromString("applySettings:")
        if displayObj.responds(to: applySel) {
            displayObj.perform(applySel, with: settings)
        }

        // Get the display ID
        guard let displayIDValue = displayObj.value(forKey: "displayID") as? UInt32, displayIDValue != 0 else {
            throw DisplayError.creationFailed(
                "Virtual display created but returned displayID 0. " +
                "Entitlement com.apple.security.temporary-exception.mach-lookup.global-name " +
                "with value com.apple.VirtualDisplay may be required."
            )
        }

        let managed = ManagedDisplay(
            displayID: displayIDValue,
            config: config,
            createdAt: Date(),
            isVirtual: true
        )

        ISTLogger.display.info("Created virtual display \(displayIDValue)")

        lock.lock()
        displays[displayIDValue] = managed
        virtualDisplayObjects[displayIDValue] = displayObj // Keep alive!
        lock.unlock()

        return managed
    }

    /// Check if CGVirtualDisplay is available on this system.
    public var isVirtualDisplayAvailable: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
    }

    /// Discover all active displays on the system.
    public func getActiveDisplays() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

        return Array(displayIDs.prefix(Int(displayCount)))
    }

    /// Get display bounds for a specific display.
    public func displayBounds(for displayID: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(displayID)
    }

    // MARK: - Use Main Display (fallback)

    /// Use the main display for testing. Not isolated, but works without entitlements.
    public func useMainDisplay(config: DisplayConfig = .init()) -> ManagedDisplay {
        ISTLogger.display.info("Using main display as fallback")
        let displayID = CGMainDisplayID()
        let managed = ManagedDisplay(
            displayID: displayID,
            config: config,
            createdAt: Date(),
            isVirtual: false
        )

        lock.lock()
        displays[displayID] = managed
        lock.unlock()

        return managed
    }

    /// Use an existing secondary display (external monitor, existing virtual display).
    public func useSecondaryDisplay(config: DisplayConfig = .init()) throws -> ManagedDisplay {
        let activeDisplays = getActiveDisplays()
        guard let secondary = activeDisplays.first(where: { $0 != CGMainDisplayID() }) else {
            throw DisplayError.creationFailed(
                "No secondary display found. Options:\n" +
                "  1. Connect an external monitor\n" +
                "  2. Use BetterDisplay to create a virtual display\n" +
                "  3. Use --display 0 to test on the main display (not isolated)"
            )
        }

        let managed = ManagedDisplay(
            displayID: secondary,
            config: config,
            createdAt: Date(),
            isVirtual: false
        )

        lock.lock()
        displays[secondary] = managed
        lock.unlock()

        return managed
    }

    // MARK: - Destroy

    public func destroyDisplay(id: CGDirectDisplayID) {
        ISTLogger.display.info("Destroying display \(id)")
        lock.lock()
        displays.removeValue(forKey: id)
        virtualDisplayObjects.removeValue(forKey: id) // Release → destroys virtual display
        lock.unlock()
    }

    public func destroyAll() {
        lock.lock()
        displays.removeAll()
        virtualDisplayObjects.removeAll()
        lock.unlock()
    }

    // MARK: - Query

    public func listDisplays() -> [ManagedDisplay] {
        lock.lock()
        defer { lock.unlock() }
        return Array(displays.values)
    }

    public func getDisplay(id: CGDirectDisplayID) -> ManagedDisplay? {
        lock.lock()
        defer { lock.unlock() }
        return displays[id]
    }

    deinit {
        destroyAll()
    }
}

// MARK: - Errors

public enum DisplayError: Error, LocalizedError {
    case unsupportedOS(String)
    case creationFailed(String)
    case displayNotFound(CGDirectDisplayID)
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS(let msg): return "Unsupported OS: \(msg)"
        case .creationFailed(let msg): return "Display creation failed: \(msg)"
        case .displayNotFound(let id): return "Display \(id) not found"
        case .captureFailed(let msg): return "Capture failed: \(msg)"
        }
    }
}
