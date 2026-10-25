import Testing
@testable import SendspinAudio

struct VolumeStepTests {
    /// What the device read back after the app wrote 0.17, 0.40 and 0.43.
    @Test func readbacksLandOnTheWrittenStep() {
        for (written, read) in [(Float32(0.17), Float32(0.17361111)), (0.40, 0.40375435), (0.43, 0.43066406)] {
            #expect(AudioDevice.sendspinVolumeStep(read) == AudioDevice.sendspinVolumeStep(written))
        }
    }

    @Test func everyStepReadsBackAsItself() {
        for step in 0...96 {
            let scalar = Float32(step) / 96
            #expect(AudioDevice.sendspinVolumeStep(scalar * scalar) == step)
        }
    }

    @Test func somePercentsShareAStep() {
        #expect(AudioDevice.sendspinVolumeStep(0.40) == AudioDevice.sendspinVolumeStep(0.41))
        #expect(AudioDevice.sendspinVolumeStep(0.10) != AudioDevice.sendspinVolumeStep(0.11))
    }

    @Test func clampsOutOfRange() {
        #expect(AudioDevice.sendspinVolumeStep(-0.1) == 0)
        #expect(AudioDevice.sendspinVolumeStep(1.2) == 96)
    }
}
