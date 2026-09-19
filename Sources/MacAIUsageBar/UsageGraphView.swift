import Charts
import SwiftUI
import UsageCore

struct UsageGraphSelection: Codable, Hashable {
    let provider: Provider
    let accountID: UUID
    let accountName: String
}

struct UsageGraphView: View {
    let selection: UsageGraphSelection
    @ObservedObject var store: UsageStore
    @State private var selectedDate: Date?

    private var samples: [UsageHistorySample] {
        store.historySamples(provider: selection.provider,
                             accountID: selection.accountID)
    }

    private func pointCount(in samples: [UsageHistorySample]) -> Int {
        samples.reduce(0) { count, sample in
            count + (sample.fiveHourUsedPercent == nil ? 0 : 1)
                + (sample.weeklyUsedPercent == nil ? 0 : 1)
        }
    }

    /// A one-minute Codex interval can produce more than ten thousand samples
    /// per week. Retain them all on disk, but render at most 1,200 evenly spaced
    /// points so opening a graph stays responsive.
    private func chartSamples(from samples: [UsageHistorySample]) -> [UsageHistorySample] {
        let maximum = 1_200
        guard samples.count > maximum else { return samples }
        let step = Double(samples.count - 1) / Double(maximum - 1)
        return (0 ..< maximum).map { offset in
            samples[Int((Double(offset) * step).rounded())]
        }
    }

    private func selectedSample(in samples: [UsageHistorySample]) -> UsageHistorySample? {
        guard let selectedDate else { return nil }
        return samples.min {
            abs($0.sampledAt.timeIntervalSince(selectedDate))
                < abs($1.sampledAt.timeIntervalSince(selectedDate))
        }
    }

    private var chartRange: ClosedRange<Date> {
        let end = Date()
        return end.addingTimeInterval(-UsageHistoryStorage.defaultRetention) ... end
    }

    var body: some View {
        let currentSamples = samples
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selection.accountName)
                        .font(.title2.weight(.semibold))
                    Text("\(selection.provider.rawValue) · 최근 7일 사용률")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(currentSamples.count)회 기록")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if currentSamples.isEmpty || pointCount(in: currentSamples) == 0 {
                ContentUnavailableView(
                    "기록된 사용량이 없습니다",
                    systemImage: "chart.xyaxis.line",
                    description: Text("다음 사용량 조회가 완료되면 그래프 기록을 시작합니다.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyChart(samples: currentSamples)
                Text("그래프를 클릭하거나 드래그하면 해당 시각의 값을 확인할 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let error = store.historyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("7일이 지난 기록은 자동으로 삭제됩니다.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 380)
    }

    private func historyChart(samples: [UsageHistorySample]) -> some View {
        let renderedSamples = chartSamples(from: samples)
        let latestSampledAt = renderedSamples.last?.sampledAt
        let selectedSample = selectedSample(in: samples)
        return Chart {
            ForEach(renderedSamples, id: \.sampledAt) { sample in
                if let percent = sample.fiveHourUsedPercent {
                    LineMark(
                        x: .value("날짜 및 시간", sample.sampledAt),
                        y: .value("사용률", percent),
                        series: .value("한도", "5시간")
                    )
                    .foregroundStyle(by: .value("한도", "5시간"))
                    .interpolationMethod(.linear)
                    if sample.sampledAt == latestSampledAt {
                        PointMark(
                            x: .value("날짜 및 시간", sample.sampledAt),
                            y: .value("사용률", percent)
                        )
                        .foregroundStyle(by: .value("한도", "5시간"))
                    }
                }
                if let percent = sample.weeklyUsedPercent {
                    LineMark(
                        x: .value("날짜 및 시간", sample.sampledAt),
                        y: .value("사용률", percent),
                        series: .value("한도", "주간")
                    )
                    .foregroundStyle(by: .value("한도", "주간"))
                    .interpolationMethod(.linear)
                    if sample.sampledAt == latestSampledAt {
                        PointMark(
                            x: .value("날짜 및 시간", sample.sampledAt),
                            y: .value("사용률", percent)
                        )
                        .foregroundStyle(by: .value("한도", "주간"))
                    }
                }
            }
            if let selectedSample {
                RuleMark(x: .value("선택한 시각", selectedSample.sampledAt))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .annotation(position: .top, spacing: 6) {
                        selectionAnnotation(selectedSample)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: ["5시간", "주간"],
            range: [Color.blue, Color.purple]
        )
        .chartLegend(position: .top, alignment: .leading, spacing: 16)
        .chartXScale(domain: chartRange)
        .chartYScale(domain: 0 ... 100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(minHeight: 280)
        .accessibilityLabel("\(selection.accountName) 최근 7일 사용률 그래프")
    }

    private func selectionAnnotation(_ sample: UsageHistorySample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sample.sampledAt,
                 format: .dateTime.month().day().hour().minute())
                .font(.caption2.weight(.semibold))
            if let percent = sample.fiveHourUsedPercent {
                Text("5시간  \(formatPercent(percent))")
                    .foregroundStyle(.blue)
            }
            if let percent = sample.weeklyUsedPercent {
                Text("주간  \(formatPercent(percent))")
                    .foregroundStyle(.purple)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
