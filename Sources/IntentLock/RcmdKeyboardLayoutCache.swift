import Carbon
import Darwin
import Foundation

/// Carbon's TIS/TSM keyboard APIs assert when called from a worker thread.
/// Capture on main; input routing and discovery only read this small value.
final class RcmdKeyboardLayoutCache {
    struct Snapshot: Equatable {
        let revision: UInt64
        let keyCodesByCharacter: [String: Int64]
    }

    static let shared = RcmdKeyboardLayoutCache()
    private let lock = NSLock()
    private let revisionStorage: UnsafeMutablePointer<Int64>
    private var value: Snapshot?
    private var started = false // main-thread owned
    private var observers: [NSObjectProtocol] = [] // main-thread owned

    private init() {
        revisionStorage = .allocate(capacity: 1)
        revisionStorage.initialize(to: 0)
    }

    deinit {
        revisionStorage.deinitialize(count: 1)
        revisionStorage.deallocate()
    }

    private var revision: UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(0, revisionStorage)) }

    var snapshot: Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        // Input callbacks only read this atomic epoch; they never wait on the
        // cache mutex or invoke Carbon, including during a main-thread refresh.
        candidate != 0 && revision == candidate
    }

    /// A worker caller never synchronously dispatches to main or calls Carbon.
    func prepare() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.prepare() }
            return
        }
        guard !started else { return }
        started = true
        for name in [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged] {
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name! as String), object: nil, queue: nil
            ) { [weak self] _ in
                // Revoke the old map before scheduling a main-thread refresh.
                self?.invalidateAndRefresh()
            }
            observers.append(observer)
        }
        invalidateAndRefresh()
    }

    func invalidateAndRefresh() {
        lock.lock()
        let requestedRevision = UInt64(bitPattern: OSAtomicIncrement64Barrier(revisionStorage))
        value = nil
        lock.unlock()
        if Thread.isMainThread { refresh(revision: requestedRevision) }
        else { DispatchQueue.main.async { self.refresh(revision: requestedRevision) } }
    }

    private func refresh(revision requestedRevision: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        let keys = Self.captureOnMainThread()
        lock.lock(); defer { lock.unlock() }
        guard revision == requestedRevision else { return }
        value = Snapshot(revision: requestedRevision, keyCodesByCharacter: keys)
    }

    private static func captureOnMainThread() -> [String: Int64] {
        precondition(Thread.isMainThread, "Carbon keyboard-layout capture must run on main")
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var result: [String: Int64] = [:], ambiguous: Set<String> = []
        for code in UInt16(0)..<128 {
            var dead: UInt32 = 0, actual = 0, text = [UniChar](repeating: 0, count: 4)
            let error = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, text.count, &actual, &text)
            guard error == noErr, actual == 1 else { continue }
            let character = String(utf16CodeUnits: text, count: actual).lowercased()
            guard character.rangeOfCharacter(from: .letters) != nil else { continue }
            if result[character] != nil { ambiguous.insert(character) }
            else { result[character] = Int64(code) }
        }
        for key in ambiguous { result.removeValue(forKey: key) }
        return result
    }
}
