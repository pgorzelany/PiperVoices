/// Linear interpolation with an exact phase carried across input windows.
struct PCMResampler {
    let inputSampleRate: Int
    let outputSampleRate: Int
    private var previousSample: Float?
    private var nextPosition = 0

    init(inputSampleRate: Int, outputSampleRate: Int) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
    }

    mutating func convert(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        guard inputSampleRate != outputSampleRate else { return Array(samples) }
        guard let last = samples.last else { return [] }
        let overlap = previousSample == nil ? 0 : 1
        let lastIndex = samples.count + overlap - 1
        var output: [Float] = []
        output.reserveCapacity((samples.count + overlap) * outputSampleRate / inputSampleRate + 1)

        while nextPosition / outputSampleRate < lastIndex {
            let index = nextPosition / outputSampleRate
            let fraction = Float(nextPosition % outputSampleRate) / Float(outputSampleRate)
            let start = index == 0 ? previousSample ?? samples[0] : samples[index - overlap]
            let end = samples[index + 1 - overlap]
            output.append(start + (end - start) * fraction)
            nextPosition += inputSampleRate
        }

        previousSample = last
        nextPosition -= lastIndex * outputSampleRate
        return output
    }

    mutating func finish() -> [Float] {
        guard let last = previousSample else { return [] }
        var tail: [Float] = []
        while nextPosition < outputSampleRate {
            tail.append(last)
            nextPosition += inputSampleRate
        }
        previousSample = nil
        nextPosition = 0
        return tail
    }
}
