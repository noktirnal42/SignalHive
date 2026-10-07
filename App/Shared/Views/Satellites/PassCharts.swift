import SwiftUI
import Charts
import SignalHiveCore

struct ElevationProfileView: View {
    let pass: PredictedPass
    let utc: Bool

    var body: some View {
        Chart(pass.track, id: \.time) { point in
            AreaMark(x: .value("Time", point.time), y: .value("Elevation", point.elevationDegrees))
                .foregroundStyle(HiveInk.cyan.opacity(0.18))
            LineMark(x: .value("Time", point.time), y: .value("Elevation", point.elevationDegrees))
                .foregroundStyle(HiveInk.cyan)
        }
        .chartYScale(domain: 0...90)
        .chartYAxis { AxisMarks(values: [0, 30, 60, 90]) { AxisGridLine(); AxisValueLabel("\($0.as(Int.self) ?? 0)°") } }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let date = value.as(Date.self) { Text(PassFormat.time(date, utc: utc)) } }
            }
        }
        .frame(height: 120)
    }
}

/// The predicted Doppler shift of the primary downlink across the pass. "Predicted": nothing has been received.
struct DopplerCurveView: View {
    let pass: PredictedPass
    let carrierHz: Double
    let utc: Bool

    var body: some View {
        Chart(pass.track, id: \.time) { point in
            LineMark(x: .value("Time", point.time),
                     y: .value("Shift", Topocentric.dopplerShiftHz(carrierHz: carrierHz, rangeRateKMPerSec: point.rangeRateKMPerSec) / 1000))
                .foregroundStyle(HiveInk.amber)
        }
        .chartYAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%+.1f kHz", v)) } }
        } }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let date = value.as(Date.self) { Text(PassFormat.time(date, utc: utc)) } }
            }
        }
        .frame(height: 120)
    }
}
