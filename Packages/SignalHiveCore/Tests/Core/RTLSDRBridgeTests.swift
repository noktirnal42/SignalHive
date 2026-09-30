import Testing
import Foundation
@testable import SignalHiveCore

struct RTLSDRBridgeTests {

    @Test func usbStringBufferHoldsTheFullSizeLibrtlsdrWrites() {
        // rtl-sdr.h: "The string arguments must provide space for up to 256 bytes." Passing a smaller buffer
        // overflows the heap; the corruption then crashes the process in an unrelated later malloc.
        var handedCapacity = 0
        let serial = RTLSDRBridge.readUSBString { buffer in
            handedCapacity = malloc_size(buffer)                      // usable bytes of the block we were given
            memset(buffer, 0, min(handedCapacity, 256))               // librtlsdr zeroes the buffer first...
            strcpy(buffer, "00000001")                                // ...then writes the descriptor string
            return 0
        }
        #expect(handedCapacity >= 256)
        #expect(serial == "00000001")
    }

    @Test func aFailedFetchYieldsNoSerial() {
        #expect(RTLSDRBridge.readUSBString { _ in -1 } == nil)
    }

    @Test func aStringThatFillsTheWholeBufferIsStillTerminated() {
        let serial = RTLSDRBridge.readUSBString { buffer in
            memset(buffer, 0x41, RTLSDRBridge.usbStringBufferSize)    // 256 'A's, no terminator from the "device"
            return 0
        }
        #expect(serial?.count == RTLSDRBridge.usbStringBufferSize - 1)
    }

    /// Smoke test for the launch path that used to crash: repeated scans must not corrupt the heap.
    /// Meaningful on a Mac with an RTL-SDR attached and librtlsdr installed; trivially passes otherwise.
    @Test @MainActor func repeatedScansDoNotCrashTheProcess() async {
        SDRDeviceManager.shared.resetScanProvidersForTesting()
        for _ in 0..<40 { await SDRDeviceManager.shared.scan() }
        #expect(!SDRDeviceManager.shared.availableDevices.isEmpty)
    }
}
