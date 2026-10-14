import XCTest

/// The measuring stick of the audio tests, checked against known signals.
final class GoertzelTests: XCTestCase {
    private func sine(_ hz: Double, amplitude: Double, seconds: Double = 1) -> [Float] {
        (0..<Int(seconds * 48_000)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / 48_000)) }
    }

    func testAFullScaleSineIsZeroDecibels() {
        XCTAssertEqual(Goertzel.level(of: 440, in: sine(440, amplitude: 1), sampleRate: 48_000), 0, accuracy: 0.05)
    }

    func testHalfTheAmplitudeIsSixDecibelsLess() {
        XCTAssertEqual(Goertzel.level(of: 440, in: sine(440, amplitude: 0.5), sampleRate: 48_000), -6.02, accuracy: 0.05)
    }

    func testAnotherFrequencyIsNotPickedUp() {
        XCTAssertLessThan(Goertzel.level(of: 880, in: sine(440, amplitude: 1), sampleRate: 48_000), -60)
    }

    func testTwoTonesAreMeasuredSeparately() {
        let mixed = zip(sine(440, amplitude: 0.25), sine(880, amplitude: 0.125)).map { $0 + $1 }
        XCTAssertEqual(Goertzel.level(of: 440, in: mixed, sampleRate: 48_000), -12.04, accuracy: 0.05)
        XCTAssertEqual(Goertzel.level(of: 880, in: mixed, sampleRate: 48_000), -18.06, accuracy: 0.05)
    }

    func testSilenceIsVeryQuiet() {
        XCTAssertLessThan(Goertzel.level(of: 440, in: [Float](repeating: 0, count: 48_000), sampleRate: 48_000), -150)
        XCTAssertLessThan(Goertzel.level(of: 440, in: [], sampleRate: 48_000), -150)
    }
}
