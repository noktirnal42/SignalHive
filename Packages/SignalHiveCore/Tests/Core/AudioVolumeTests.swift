import Testing
@testable import SignalHiveCore

struct AudioVolumeTests {
    @Test func sliderPositionUsesAPerceptualTaper() {
        #expect(AudioVolume(level: 0).gain == 0)
        #expect(AudioVolume(level: 1).gain == 1)
        #expect(AudioVolume(level: 0.5).gain == 0.25)        // half-way on the slider is not half the amplitude
    }

    @Test func mutedIsSilentButRemembersTheLevel() {
        var volume = AudioVolume(level: 0.8, isMuted: true)
        #expect(volume.gain == 0)
        volume.isMuted = false
        #expect(volume.gain > 0.6)
    }

    @Test func outOfRangeLevelsAreClamped() {
        #expect(AudioVolume(level: 3).gain == 1)
        #expect(AudioVolume(level: -1).gain == 0)
    }

    @Test func theDefaultIsAudibleButNotLoud() {
        let volume = AudioVolume()
        #expect(volume.isMuted == false)
        #expect(volume.gain > 0.2 && volume.gain < 0.8)
    }

    @Test func aPipelineKeepsItsVolumeSeparateFromDemodSettings() async {
        let pipeline = DSPPipeline(device: TestSignalDevice())
        await pipeline.setVolume(AudioVolume(level: 0.4, isMuted: true))
        let stored = await pipeline.currentConfig.volume
        #expect(stored == AudioVolume(level: 0.4, isMuted: true))
    }
}
