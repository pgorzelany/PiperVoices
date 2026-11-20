import Testing
@testable import EnclavePiperSpeech

@Test(arguments: [16_000, 22_050, 24_000, 44_100])
func preservesPhaseAcrossDecoderWindows(inputRate: Int) {
    let chunks: [[Float]] = [[0.2], [], [0.4, -0.9, 0.7], [0.1], [-0.3, 0.6]]
    let input = chunks.flatMap { $0 }
    let outputRate = 24_000
    var split = PCMResampler(inputSampleRate: inputRate, outputSampleRate: outputRate)
    var contiguous = PCMResampler(inputSampleRate: inputRate, outputSampleRate: outputRate)

    var splitPCM = chunks.flatMap { $0.withUnsafeBufferPointer { split.convert($0) } }
    splitPCM.append(contentsOf: split.finish())

    var contiguousPCM = input.withUnsafeBufferPointer { contiguous.convert($0) }
    contiguousPCM.append(contentsOf: contiguous.finish())

    #expect(splitPCM == contiguousPCM)
    #expect(splitPCM.count == (input.count * outputRate + inputRate - 1) / inputRate)
}

@Test
func interpolatesAcrossWindowsAndFlushesTheLastSample() {
    var converter = PCMResampler(inputSampleRate: 12_000, outputSampleRate: 24_000)
    #expect([Float]().withUnsafeBufferPointer { converter.convert($0) }.isEmpty)
    #expect([Float(0)].withUnsafeBufferPointer { converter.convert($0) }.isEmpty)
    #expect([Float(1)].withUnsafeBufferPointer { converter.convert($0) } == [0, 0.5])
    #expect(converter.finish() == [1, 1])
    #expect(converter.finish().isEmpty)
}
