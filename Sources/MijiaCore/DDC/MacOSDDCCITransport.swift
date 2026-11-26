import Foundation

#if os(macOS)
import IOKit
import Darwin

private typealias IOAVServiceRef = CFTypeRef
private typealias IOAVServiceCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> IOAVServiceRef?
private typealias IOAVServiceReadI2CFn = @convention(c) (IOAVServiceRef?, UInt32, UInt8, UnsafeMutablePointer<UInt8>, UInt32) -> Int32
private typealias IOAVServiceWriteI2CFn = @convention(c) (IOAVServiceRef?, UInt32, UInt8, UnsafePointer<UInt8>, UInt32) -> Int32

public final class MacOSDDCCITransport: DDCCITransport, @unchecked Sendable {
    private let create: IOAVServiceCreateWithServiceFn?
    private let read: IOAVServiceReadI2CFn?
    private let write: IOAVServiceWriteI2CFn?

    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/AppleGraphicsControl.framework/AppleGraphicsControl", RTLD_LAZY)
        create = handle.flatMap { unsafeBitCast(dlsym($0, "IOAVServiceCreateWithService"), to: IOAVServiceCreateWithServiceFn.self) }
        read = handle.flatMap { unsafeBitCast(dlsym($0, "IOAVServiceReadI2C"), to: IOAVServiceReadI2CFn.self) }
        write = handle.flatMap { unsafeBitCast(dlsym($0, "IOAVServiceWriteI2C"), to: IOAVServiceWriteI2CFn.self) }
    }

    public func listDisplays() throws -> [DDCCIDisplayDescriptor] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [DDCCIDisplayDescriptor] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard external(service), let descriptor = descriptor(for: service) else { continue }
            result.append(descriptor)
        }
        return result
    }

    public func exchange(displayId: String, chipAddress: UInt8, request: [UInt8],
                         replyLength: Int, readDelay: TimeInterval) throws -> [UInt8] {
        guard let service = service(for: displayId), let create, let read, let write else {
            throw DDCCIError.transportUnavailable
        }
        guard let av = create(kCFAllocatorDefault, service) else { throw DDCCIError.transportUnavailable }
        let requestResult = request.withUnsafeBufferPointer {
            write(av, UInt32(chipAddress), DDCCIFrame.dataAddress, $0.baseAddress!, UInt32($0.count))
        }
        guard requestResult == 0 else { throw DDCCIError.ioFailure(requestResult) }
        guard replyLength > 0 else { return [] }
        usleep(useconds_t(readDelay * 1_000_000))
        var bytes = Array(repeating: UInt8(0), count: replyLength)
        let result = bytes.withUnsafeMutableBufferPointer {
            read(av, UInt32(chipAddress), DDCCIFrame.dataAddress, $0.baseAddress!, UInt32($0.count))
        }
        guard result == 0 else { throw DDCCIError.ioFailure(result) }
        return bytes
    }

    private func external(_ service: io_service_t) -> Bool {
        guard let property = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return false }
        return (property as? String) == "External"
    }

    private func service(for id: String) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            if "\(registryID)" == id { return service }
            IOObjectRelease(service)
        }
        return nil
    }

    private func descriptor(for service: io_service_t) -> DDCCIDisplayDescriptor? {
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)
        let id = "\(registryID)"
        let name = (IORegistryEntryCreateCFProperty(service, "ProductName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? "External Display"
        let manufacturer = (IORegistryEntryCreateCFProperty(service, "Manufacturer" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
        var parent: io_service_t = 0
        let bridge: Bool
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            bridge = (IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) == "AppleDCPMCDP29XX"
            IOObjectRelease(parent)
        } else { bridge = false }
        return DDCCIDisplayDescriptor(id: id, name: name, manufacturer: manufacturer, model: name,
                                      isExternal: true, supportsMCDP29XXBridge: bridge)
    }
}
#endif
