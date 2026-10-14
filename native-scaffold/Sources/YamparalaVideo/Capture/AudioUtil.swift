import Accelerate
import AVFoundation

enum AudioUtil {
    /// Applies linear `gain` to the buffer in place and returns its peak (0...1).
    ///
    /// Scaling in place avoids a copy per packet. The buffers ScreenCaptureKit
    /// and AVCapture hand us are not reused after the callback returns, and we
    /// are the only consumer, so mutating them is safe here.
    @discardableResult
    static func applyGain(_ sampleBuffer: CMSampleBuffer, gain: Float) -> Float {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return 0 }

        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil) == noErr, listSize > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr
        else { return 0 }
        _ = blockBuffer  // keeps the backing store alive for this scope

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bitsPerChannel = asbd.mBitsPerChannel
        var peak: Float = 0

        for buffer in UnsafeMutableAudioBufferListPointer(listPtr) {
            guard let data = buffer.mData else { continue }

            if isFloat, bitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                let samples = data.bindMemory(to: Float.self, capacity: count)
                if gain != 1 {
                    var g = gain
                    vDSP_vsmul(samples, 1, &g, samples, 1, vDSP_Length(count))
                }
                var localPeak: Float = 0
                vDSP_maxmgv(samples, 1, &localPeak, vDSP_Length(count))
                peak = max(peak, localPeak)

            } else if !isFloat, bitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                guard count > 0 else { continue }
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                var localPeak: Float = 0
                for i in 0..<count {
                    let scaled = gain == 1
                        ? Float(samples[i])
                        : (Float(samples[i]) * gain).clamped(to: -32768...32767)
                    if gain != 1 { samples[i] = Int16(scaled) }
                    localPeak = max(localPeak, abs(scaled) / 32768)
                }
                peak = max(peak, localPeak)
            }
        }

        return min(peak, 1)
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
