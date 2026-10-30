import Darwin
import Foundation

/// Physical memory footprint in MB; aborts the process above `limitMB` (runaway-memory guard).
@discardableResult
func memoryGuard(_ label: String = "", limitMB: Double = 4000) -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    let mb = kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    if mb > limitMB {
        FileHandle.standardError.write(Data("memory guard tripped at \(label): \(Int(mb)) MB\n".utf8))
        exit(3)
    }
    return mb
}
