import CoreAudio

/// The IOProc's audio copy, kept as a pure function over buffer lists so it can be unit-tested.
///
/// Both sides are Float32 (the aggregate device's canonical format), each buffer interleaved with
/// `mNumberChannels` channels. Channels are numbered across all buffers in order. Input channel n
/// goes to output channel n; a mono input is copied to the first two output channels. Output
/// channels with no input are zeroed. Real-time safe: no allocation, no locks.
enum AudioBufferCopy {
    /// - Parameter skipInputBuffers: leading input buffers to ignore (the output device's own
    ///   input streams, which the aggregate lists before the tap's).
    static func copy(
        from input: UnsafePointer<AudioBufferList>,
        to output: UnsafeMutablePointer<AudioBufferList>,
        skipInputBuffers: Int = 0
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outputs {
            if let data = buffer.mData {
                data.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
            }
        }

        let inputChannelCount = channelCount(inputs, skipping: skipInputBuffers)
        guard inputChannelCount > 0 else { return }

        var outputChannel = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else {
                outputChannel += channels
                continue
            }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
            for c in 0..<channels {
                let sourceChannel = inputChannelCount == 1 ? (outputChannel + c < 2 ? 0 : -1) : outputChannel + c
                if sourceChannel >= 0, sourceChannel < inputChannelCount {
                    copyChannel(inputs, skipping: skipInputBuffers, channel: sourceChannel,
                                to: data, channel: c, of: channels, frames: frames)
                }
            }
            outputChannel += channels
        }
    }

    /// Highest absolute Float32 sample across all buffers. Real-time safe.
    static func peak(of list: UnsafeMutablePointer<AudioBufferList>) -> Float32 {
        var peak: Float32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            for index in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size {
                peak = max(peak, abs(data[index]))
            }
        }
        return peak
    }

    private static func channelCount(_ buffers: UnsafeMutableAudioBufferListPointer, skipping: Int) -> Int {
        var count = 0
        for index in skipping..<max(skipping, buffers.count) {
            count += Int(buffers[index].mNumberChannels)
        }
        return count
    }

    private static func copyChannel(
        _ inputs: UnsafeMutableAudioBufferListPointer, skipping: Int, channel: Int,
        to destination: UnsafeMutablePointer<Float32>, channel destinationChannel: Int, of destinationChannels: Int,
        frames: Int
    ) {
        var first = 0
        for index in skipping..<max(skipping, inputs.count) {
            let buffer = inputs[index]
            let channels = Int(buffer.mNumberChannels)
            if channel < first + channels {
                guard let source = buffer.mData?.assumingMemoryBound(to: Float32.self) else { return }
                let sourceFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
                let offset = channel - first
                for frame in 0..<min(frames, sourceFrames) {
                    destination[frame * destinationChannels + destinationChannel] = source[frame * channels + offset]
                }
                return
            }
            first += channels
        }
    }
}
