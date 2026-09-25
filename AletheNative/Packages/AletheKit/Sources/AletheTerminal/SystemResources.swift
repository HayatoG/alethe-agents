import Darwin
import Foundation

/// Memory of the Mac and of process trees, and scheduling priority of background terminals
/// (upstream `stats.rs` memory sampling and `set_pty_priority`).
public enum SystemResources {
    public struct Memory: Equatable, Sendable {
        public var totalMB: Double
        /// What apps can still get without swapping: free, inactive, speculative and purgeable pages.
        public var availableMB: Double

        public init(totalMB: Double, availableMB: Double) {
            self.totalMB = totalMB
            self.availableMB = availableMB
        }
    }

    private static let megabyte = 1024.0 * 1024.0

    public static func memory() -> Memory {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / megabyte
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Memory(totalMB: total, availableMB: total) }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        return Memory(totalMB: total, availableMB: Double(pages) * Double(sysconf(_SC_PAGESIZE)) / megabyte)
    }

    /// A process's physical footprint (what Activity Monitor calls Memory), in MB; 0 when it is gone.
    public static func footprintMB(of pid: pid_t) -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / megabyte : 0
    }

    /// Footprint of `root` and every descendant (agents run node, git, language servers below the
    /// shell).
    public static func treeFootprintMB(of root: pid_t, parents: [pid_t: pid_t]) -> Double {
        ProcessTree.descendants(of: root, parents: parents).reduce(0) { $0 + footprintMB(of: $1) }
    }

    /// Puts a process tree in the background band (lower CPU and I/O priority) or back to normal.
    /// Unlike `nice`, this can be undone without privileges.
    public static func setBackground(_ background: Bool, tree root: pid_t, parents: [pid_t: pid_t]) {
        for pid in ProcessTree.descendants(of: root, parents: parents) {
            setpriority(PRIO_DARWIN_PROCESS, UInt32(pid), background ? PRIO_DARWIN_BG : 0)
        }
    }
}
