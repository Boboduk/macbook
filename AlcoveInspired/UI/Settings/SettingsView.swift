import IslandCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case activities
    case system

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .activities: return "Activities"
        case .system: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .activities: return "square.stack.3d.up"
        case .system: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralSettingsView()
                case .appearance: AppearanceSettingsView()
                case .activities: ActivitiesSettingsView()
                case .system: SystemSettingsView()
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 440)
        }
    }
}

/// A slider row with a label and a formatted value.
struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .frame(maxWidth: 280)
        } label: {
            Text(title)
        }
    }
}

enum SettingsFormat {
    static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func multiplier(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    static func points(_ value: Double) -> String {
        "\(Int(value.rounded())) pt"
    }
}
