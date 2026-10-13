import AppKit
import Darwin

/// Some ordinary GUI apps (including iLoader) have no AppKit launchDate.
/// Use the kernel's exact process birth timestamp rather than a guessed date
/// or a PID-only identity. Failure to read it remains an unconfirmed identity.
public enum NativeProcessLaunchDate {
    public static func kernelDate(pid: pid_t) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec)
            + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    public static func date(for app: NSRunningApplication) -> Date? {
        guard !app.isTerminated else { return nil }
        return app.launchDate ?? kernelDate(pid: app.processIdentifier)
    }
}

extension NSRunningApplication {
    var intentVisibilityLaunchDate: Date? { NativeProcessLaunchDate.date(for: self) }
}
