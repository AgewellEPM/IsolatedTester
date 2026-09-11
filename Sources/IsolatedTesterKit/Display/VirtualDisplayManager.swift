import AppKit
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
    @MainActor
    public func createDisplay(config: DisplayConfig = .init()) throws -> ManagedDisplay {
        // A bare CLI has no AppKit connection to WindowServer. Establish it on
        // the main actor before asking CoreGraphics to publish a display.
        _ = NSApplication.shared
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

        // Match the descriptor contract used by Chromium's macOS virtual-display
        // test host. Recent WindowServer builds reject underspecified descriptors.
        descriptor.setValue(config.name, forKey: "name")
        descriptor.setValue(config.width, forKey: "maxPixelsWide")
        descriptor.setValue(config.height, forKey: "maxPixelsHigh")
        descriptor.setValue(
            CGSize(
                width: 25.4 * Double(config.width) / Double(config.ppi),
                height: 25.4 * Double(config.height) / Double(config.ppi)),
            forKey: "sizeInMillimeters")
        descriptor.setValue(CGPoint(x: 0.3125, y: 0.3291), forKey: "whitePoint")
        descriptor.setValue(CGPoint(x: 0.1494, y: 0.0557), forKey: "bluePrimary")
        descriptor.setValue(CGPoint(x: 0.2559, y: 0.6983), forKey: "greenPrimary")
        descriptor.setValue(CGPoint(x: 0.6797, y: 0.3203), forKey: "redPrimary")
        let serial = arc4random()
        descriptor.setValue(UInt32(505), forKey: "vendorID")
        descriptor.setValue(UInt32(0), forKey: "productID")
        descriptor.setValue(serial, forKey: "serialNum")
        descriptor.setValue(serial, forKey: "serialNumber")

        // The descriptor contract exposes `queue`; using setDispatchQueue: leaves
        // that property nil on current macOS even though the selector exists.
        let queue = DispatchQueue(label: "com.isolatedtester.virtualdisplay")
        descriptor.setValue(queue, forKey: "queue")

        // Create the virtual display via alloc + initWithDescriptor:
        // IMPORTANT: must use alloc/init pattern, NOT init() then perform(initSel)
        // because perform() on init methods double-initializes and corrupts memory.
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithDescriptor:")

        guard let allocated = (displayClass as AnyObject).perform(allocSel)?.takeUnretainedValue(),
              let initialized = allocated.perform(initSel, with: descriptor)?.takeRetainedValue() as? NSObject else {
            throw DisplayError.creationFailed(
                "CGVirtualDisplay initWithDescriptor: returned nil; WindowServer rejected the virtual-display descriptor."
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
        let hiDPI = config.ppi > 100
        let modeWidth = hiDPI ? config.width / 2 : config.width
        let modeHeight = hiDPI ? config.height / 2 : config.height

        // NSInvocation is not available in Swift, so use the KVC-settable init() as fallback
        // and set via the constructor if available. For CGVirtualDisplayMode, the init args
        // are primitive types which perform() can't pass, so we use an NSInvocation workaround.
        let mode: NSObject
        let allocatedMode = (modeClass as AnyObject).perform(modeAllocSel)?.takeUnretainedValue() as? NSObject
        if let am = allocatedMode, am.responds(to: modeInitSel) {
            // Use objc_msgSend for primitive parameters that perform() can't handle
            typealias ModeInitFn = @convention(c) (AnyObject, Selector, Int, Int, Double) -> AnyObject?
            let fn = unsafeBitCast(class_getMethodImplementation(modeClass, modeInitSel), to: ModeInitFn.self)
            if let result = fn(am, modeInitSel, modeWidth, modeHeight, 60.0) as? NSObject {
                mode = result
            } else {
                // Fallback: use default init and try KVC — safe cast to avoid crash
                // if CGVirtualDisplayMode is not an NSObject subclass.
                guard let modeType = modeClass as? NSObject.Type else {
                    throw DisplayError.creationFailed("CGVirtualDisplayMode is not an NSObject subclass")
                }
                mode = modeType.init()
                mode.setValue(modeWidth, forKey: "width")
                mode.setValue(modeHeight, forKey: "height")
                mode.setValue(60.0, forKey: "refreshRate")
            }
        } else {
            // Safe cast for the else-branch fallback init as well.
            guard let modeType = modeClass as? NSObject.Type else {
                throw DisplayError.creationFailed("CGVirtualDisplayMode is not an NSObject subclass")
            }
            mode = modeType.init()
            mode.setValue(modeWidth, forKey: "width")
            mode.setValue(modeHeight, forKey: "height")
            mode.setValue(60.0, forKey: "refreshRate")
        }

        // Create settings — safe cast to avoid crash if the class is not an NSObject subclass.
        guard let settingsType = settingsClass as? NSObject.Type else {
            throw DisplayError.creationFailed("CGVirtualDisplaySettings is not an NSObject subclass")
        }
        let settings = settingsType.init()
        settings.setValue(hiDPI, forKey: "hiDPI")
        settings.setValue(0, forKey: "rotation")
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

        // Register BEFORE the corner-pin and mirror check so a violation can
        // tear the display down through the normal destroyDisplay path —
        // releasing the strong ObjC ref is what actually removes the virtual
        // display from WindowServer.
        lock.lock()
        displays[displayIDValue] = managed
        virtualDisplayObjects[displayIDValue] = displayObj // Keep alive!
        lock.unlock()

        // Arrange the new display corner-diagonal to the ENTIRE existing
        // arrangement. Left to WindowServer's default edge-adjacent placement,
        // the user's REAL cursor can slide off a shared edge into the
        // invisible display and vanish ("trapped and couldn't get out",
        // 2026-08-18). Corner adjacency is a valid arrangement with no shared
        // edge to cross. Best-effort: a failure leaves default adjacency,
        // which is survivable but leaky — so it's logged, not fatal.
        cornerPin(displayID: displayIDValue)

        // Post-create mirror invariant: macOS may AUTO-MIRROR on
        // CGVirtualDisplay creation (GhostBridge's equivalent code observed
        // creation auto-mirroring its display). A mirrored REAL panel is a
        // desktop takeover, so every create verifies, heals, or refuses —
        // this is NOT best-effort.
        try enforcePostCreateMirrorInvariant(virtualDisplayID: displayIDValue)

        return managed
    }

    /// Pin a display's origin to the bottom-right corner of the UNION of every
    /// OTHER online display, so the new display shares only a corner point —
    /// never an edge — with ANY display in the arrangement.
    ///
    /// Why the union and NOT CGMainDisplayID() (live-fire, 2026-08-25): with
    /// the GhostBridge half-screen workspace active, its virtual display is
    /// main at (0,0) and the physical panel is parked to its right. Pinning
    /// relative to the main display's bounds dropped the tester display
    /// inside/adjacent to the parked panel's slot, and the resulting
    /// reconfiguration killed the workspace (presentation_health=failed
    /// reason=display_reconfiguration). On a single-display desktop the union
    /// IS the main display's bounds, so the original intent is unchanged.
    ///
    /// The pin is also VERIFIED: WindowServer may normalize the requested
    /// arrangement, silently turning corner adjacency back into edge adjacency
    /// (observed live: requested (1920,1080), landed edge-adjacent (1920,0)).
    /// On mismatch the pin retries ONCE against a fresh union; if still wrong
    /// it logs loudly but does NOT fail the session — visibility over refusal;
    /// the mirror invariant below still guards against takeover.
    ///
    /// Greppable outcomes (one per run):
    ///   cornerPin=applied origin=(x,y) union=(WxH) displays=N
    ///   cornerPin=unverified origin=(x,y) requested=(x,y)
    ///   cornerPin=skipped reason=...
    ///   cornerPin=failed reason=...
    private func cornerPin(displayID: CGDirectDisplayID) {
        for attempt in 1...2 {
            // Union of every ONLINE display except the one being pinned.
            // Online (not just active) so mirrored/sleeping panels still
            // count — they occupy arrangement space and regain edges at wake.
            // Recomputed per attempt: a normalization that moved the first
            // pin may have moved other displays too.
            let others = onlineDisplays().filter { $0 != displayID }
            guard !others.isEmpty else {
                ISTLogger.display.error(
                    "cornerPin=skipped reason=no_other_displays display=\(displayID) — nothing to pin against")
                return
            }
            let union = others.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
            guard !union.isEmpty else {
                // All bounds read back empty (displays went offline mid-census).
                // Pinning at (0,0) would OVERLAP the main display — refuse.
                ISTLogger.display.error(
                    "cornerPin=skipped reason=empty_union display=\(displayID) — keeps default adjacency")
                return
            }
            let target = CGPoint(x: union.maxX, y: union.maxY)

            guard applyOrigin(displayID: displayID, target: target) else {
                return // applyOrigin logged the failure loudly
            }

            // Verify the pin actually stuck — never trust the transaction's
            // return code alone.
            let actual = CGDisplayBounds(displayID).origin
            if abs(actual.x - target.x) <= 1, abs(actual.y - target.y) <= 1 {
                ISTLogger.display.info(
                    "cornerPin=applied origin=(\(Int(actual.x)),\(Int(actual.y))) union=(\(Int(union.width))x\(Int(union.height))) displays=\(others.count) attempt=\(attempt)")
                return
            }
            if attempt == 2 {
                ISTLogger.display.error(
                    "cornerPin=unverified origin=(\(Int(actual.x)),\(Int(actual.y))) requested=(\(Int(target.x)),\(Int(target.y))) union=(\(Int(union.width))x\(Int(union.height))) displays=\(others.count) — WindowServer normalized the arrangement; display \(displayID) may be edge-adjacent")
            }
        }
    }

    /// One display-configuration transaction moving `displayID`'s origin to
    /// `target`. Returns true when the transaction COMMITTED — not that the
    /// origin stuck. Callers must verify by re-reading CGDisplayBounds.
    private func applyOrigin(displayID: CGDirectDisplayID, target: CGPoint) -> Bool {
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let configRef else {
            ISTLogger.display.error(
                "cornerPin=failed reason=begin_configuration display=\(displayID) — keeps default adjacency")
            return false
        }
        CGConfigureDisplayOrigin(configRef, displayID, Int32(target.x), Int32(target.y))
        let result = CGCompleteDisplayConfiguration(configRef, .forSession)
        guard result == .success else {
            ISTLogger.display.error(
                "cornerPin=failed reason=complete_configuration code=\(result.rawValue) display=\(displayID) — keeps default adjacency")
            return false
        }
        return true
    }

    // MARK: - Post-create mirror invariant

    /// Our private virtual displays are stamped vendor 505 / product 0 in the
    /// descriptor above. Any online display NOT carrying that stamp is the
    /// user's REAL hardware.
    private func isOwnVirtualDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 505 && CGDisplayModelNumber(id) == 0
    }

    /// Every display currently online (active, mirrored, or sleeping).
    /// Mirror members drop OUT of the active list, so the online list is the
    /// only honest census for mirror auditing.
    private func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// REAL displays currently violating the mirror invariant relative to the
    /// new virtual display: in a mirror set involving it, or — for the real
    /// main panel — mirroring anything at all.
    private func mirrorViolatingRealDisplays(virtualDisplayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        let realDisplays = onlineDisplays().filter { !isOwnVirtualDisplay($0) }
        let virtualMirrors = CGDisplayMirrorsDisplay(virtualDisplayID)
        let virtualInSet = CGDisplayIsInMirrorSet(virtualDisplayID) != 0
        return realDisplays.filter { real in
            let realMirrors = CGDisplayMirrorsDisplay(real)
            let involvedWithVirtual =
                realMirrors == virtualDisplayID     // real panel mirrors the virtual display
                || virtualMirrors == real           // virtual display mirrors the real panel
                || (virtualInSet && CGDisplayIsInMirrorSet(real) != 0
                    && CGDisplayPrimaryDisplay(real) == CGDisplayPrimaryDisplay(virtualDisplayID))
            let mainPanelMirroring = real == CGMainDisplayID() && realMirrors != kCGNullDirectDisplay
            return involvedWithVirtual || mainPanelMirroring
        }
    }

    /// Verify no REAL display was pulled into a mirror set by creating the
    /// virtual display. On violation: heal in ONE display-configuration
    /// transaction, re-check, and if still mirrored destroy the virtual
    /// display and throw — creating a session must NEVER be allowed to keep
    /// the user's panel mirrored.
    ///
    /// Greppable outcomes (one per run):
    ///   postCreateMirrorCheck=clean
    ///   postCreateMirrorCheck=violation_detected  (+ _healed or _unhealed)
    private func enforcePostCreateMirrorInvariant(virtualDisplayID: CGDirectDisplayID) throws {
        let affected = mirrorViolatingRealDisplays(virtualDisplayID: virtualDisplayID)
        if affected.isEmpty {
            ISTLogger.display.debug("postCreateMirrorCheck=clean virtualDisplay=\(virtualDisplayID)")
            return
        }

        let affectedList = affected.map { String($0) }.joined(separator: ",")
        ISTLogger.display.error(
            "postCreateMirrorCheck=violation_detected realDisplays=\(affectedList, privacy: .public) mirrored after creating virtual display \(virtualDisplayID) — unmirroring now")

        // One transaction: unmirror every affected real display, and the
        // virtual display itself if it joined a set (breaking a set where the
        // virtual member mirrors a real primary requires unmirroring the
        // virtual member, not the primary).
        var configRef: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&configRef) == .success, let configRef {
            for real in affected {
                CGConfigureDisplayMirrorOfDisplay(configRef, real, kCGNullDirectDisplay)
            }
            if CGDisplayMirrorsDisplay(virtualDisplayID) != kCGNullDirectDisplay
                || CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                CGConfigureDisplayMirrorOfDisplay(configRef, virtualDisplayID, kCGNullDirectDisplay)
            }
            let result = CGCompleteDisplayConfiguration(configRef, .forSession)
            if result != .success {
                ISTLogger.display.error("postCreateMirrorCheck unmirror transaction failed (\(result.rawValue))")
            }
        } else {
            ISTLogger.display.error("postCreateMirrorCheck: CGBeginDisplayConfiguration failed — cannot unmirror")
        }

        // Re-check: healing must be proven, not assumed.
        let stillMirrored = mirrorViolatingRealDisplays(virtualDisplayID: virtualDisplayID)
        guard stillMirrored.isEmpty else {
            let stillList = stillMirrored.map { String($0) }.joined(separator: ",")
            ISTLogger.display.error(
                "postCreateMirrorCheck=violation_unhealed realDisplays=\(stillList, privacy: .public) still mirrored — destroying virtual display \(virtualDisplayID)")
            destroyDisplay(id: virtualDisplayID)
            throw DisplayError.creationFailed(
                "Post-create mirror invariant violated and unmirror FAILED: real display(s) [\(stillList)] "
                + "remain in a mirror set after creating virtual display \(virtualDisplayID). "
                + "The virtual display was destroyed; run gb-restore to restore your display layout."
            )
        }
        ISTLogger.display.info(
            "postCreateMirrorCheck=violation_healed unmirrored realDisplays=\(affectedList, privacy: .public)")
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

    // NOTE: useSecondaryDisplay() was removed 2026-08-25. It was dead public
    // API with zero callers that could register a REAL display (external
    // monitor / foreign virtual display) as a test surface — the exact
    // takeover shape the 2026-08-18 incident fixed elsewhere.

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
