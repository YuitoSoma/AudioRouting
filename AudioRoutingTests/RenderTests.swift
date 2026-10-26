import CoreAudio
import XCTest
@testable import AudioRouting

/// Tests for the IOProc copy (AudioBufferCopy), using hand-built AudioBufferLists.
final class RenderTests: XCTestCase {
    /// Owns Float32 storage for an AudioBufferList with the given channels per buffer.
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float32>] = []

        init(channelsPerBuffer: [Int], frames: Int, fill: (_ buffer: Int, _ frame: Int, _ channel: Int) -> Float32 = { _, _, _ in 0 }) {
            list = AudioBufferList.allocate(maximumBuffers: max(1, channelsPerBuffer.count))
            list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channelsPerBuffer.count)
            for (index, channels) in channelsPerBuffer.enumerated() {
                let samples = UnsafeMutablePointer<Float32>.allocate(capacity: frames * channels)
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        samples[frame * channels + channel] = fill(index, frame, channel)
                    }
                }
                storage.append(samples)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(frames * channels * MemoryLayout<Float32>.size),
                    mData: samples
                )
            }
        }

        func sample(buffer: Int, frame: Int, channel: Int) -> Float32 {
            storage[buffer][frame * Int(list[buffer].mNumberChannels) + channel]
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    func testCopiesInterleavedStereoToStereo() {
        let input = Buffers(channelsPerBuffer: [2], frames: 4) { _, frame, channel in Float32(frame * 10 + channel) }
        let output = Buffers(channelsPerBuffer: [2], frames: 4) { _, _, _ in 99 }

        AudioBufferCopy.copy(from: input.list.unsafePointer, to: output.list.unsafeMutablePointer)

        for frame in 0..<4 {
            XCTAssertEqual(output.sample(buffer: 0, frame: frame, channel: 0), Float32(frame * 10))
            XCTAssertEqual(output.sample(buffer: 0, frame: frame, channel: 1), Float32(frame * 10 + 1))
        }
    }

    func testCopiesInterleavedInputToNonInterleavedOutput() {
        let input = Buffers(channelsPerBuffer: [2], frames: 3) { _, frame, channel in Float32(frame + channel * 100) }
        let output = Buffers(channelsPerBuffer: [1, 1], frames: 3)

        AudioBufferCopy.copy(from: input.list.unsafePointer, to: output.list.unsafeMutablePointer)

        XCTAssertEqual((0..<3).map { output.sample(buffer: 0, frame: $0, channel: 0) }, [0, 1, 2])
        XCTAssertEqual((0..<3).map { output.sample(buffer: 1, frame: $0, channel: 0) }, [100, 101, 102])
    }

    func testZeroesOutputChannelsWithoutInput() {
        let input = Buffers(channelsPerBuffer: [2], frames: 2) { _, _, _ in 1 }
        let output = Buffers(channelsPerBuffer: [4], frames: 2) { _, _, _ in 99 }

        AudioBufferCopy.copy(from: input.list.unsafePointer, to: output.list.unsafeMutablePointer)

        for frame in 0..<2 {
            XCTAssertEqual(output.sample(buffer: 0, frame: frame, channel: 0), 1)
            XCTAssertEqual(output.sample(buffer: 0, frame: frame, channel: 1), 1)
            XCTAssertEqual(output.sample(buffer: 0, frame: frame, channel: 2), 0)
            XCTAssertEqual(output.sample(buffer: 0, frame: frame, channel: 3), 0)
        }
    }

    func testMonoInputGoesToBothStereoChannels() {
        let input = Buffers(channelsPerBuffer: [1], frames: 2) { _, frame, _ in Float32(frame + 1) }
        let output = Buffers(channelsPerBuffer: [2], frames: 2)

        AudioBufferCopy.copy(from: input.list.unsafePointer, to: output.list.unsafeMutablePointer)

        XCTAssertEqual(output.sample(buffer: 0, frame: 1, channel: 0), 2)
        XCTAssertEqual(output.sample(buffer: 0, frame: 1, channel: 1), 2)
    }

    func testSkipsOutputDeviceInputStreams() {
        // Buffer 0 is the headset mic (must be ignored), buffer 1 is the tap.
        let input = Buffers(channelsPerBuffer: [1, 2], frames: 2) { buffer, _, channel in
            buffer == 0 ? -1 : Float32(channel + 5)
        }
        let output = Buffers(channelsPerBuffer: [2], frames: 2)

        AudioBufferCopy.copy(from: input.list.unsafePointer, to: output.list.unsafeMutablePointer, skipInputBuffers: 1)

        XCTAssertEqual(output.sample(buffer: 0, frame: 0, channel: 0), 5)
        XCTAssertEqual(output.sample(buffer: 0, frame: 0, channel: 1), 6)
    }

    func testCopiesOnlyFramesBothSidesHave() {
        let input = Buffers(channelsPerBuffer: [2], frames: 2) { _, _, _ in 1 }
        let output = Buffers(channelsPerBuffer: [2], frames: 4) { _, _, _ in 99 }

        AudioBufferCopy.copy(from: input.list.unsafePointer, to: output.list.unsafeMutablePointer)

        XCTAssertEqual(output.sample(buffer: 0, frame: 1, channel: 1), 1)
        XCTAssertEqual(output.sample(buffer: 0, frame: 2, channel: 0), 0)
        XCTAssertEqual(output.sample(buffer: 0, frame: 3, channel: 1), 0)
    }

    func testEmptyInputProducesSilence() {
        let input = Buffers(channelsPerBuffer: [], frames: 0)
        let output = Buffers(channelsPerBuffer: [2], frames: 2) { _, _, _ in 99 }

        AudioBufferCopy.copy(from: input.list.unsafePointer, to: output.list.unsafeMutablePointer)

        XCTAssertEqual(output.sample(buffer: 0, frame: 0, channel: 0), 0)
        XCTAssertEqual(output.sample(buffer: 0, frame: 1, channel: 1), 0)
    }

    func testPeakIsHighestAbsoluteSampleAcrossBuffers() {
        let output = Buffers(channelsPerBuffer: [1, 2], frames: 3) { buffer, frame, channel in
            buffer == 1 && frame == 2 && channel == 1 ? -0.75 : 0.25
        }
        XCTAssertEqual(AudioBufferCopy.peak(of: output.list.unsafeMutablePointer), 0.75)
    }

    func testPeakOfSilenceIsZero() {
        let output = Buffers(channelsPerBuffer: [2], frames: 4)
        XCTAssertEqual(AudioBufferCopy.peak(of: output.list.unsafeMutablePointer), 0)
    }
}
