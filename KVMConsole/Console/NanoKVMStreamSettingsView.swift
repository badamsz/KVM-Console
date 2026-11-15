import KVMKit
import SwiftUI

/// Edits the codec and encoder settings a NanoKVM Go's console video uses.
/// Saved with the device and sent on every connect, because the NanoKVM
/// keeps them only in memory and its web page sends its own on every visit.
struct NanoKVMStreamSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings: NanoKVMStreamSettings
    let onSave: (NanoKVMStreamSettings) -> Void

    init(settings: NanoKVMStreamSettings, onSave: @escaping (NanoKVMStreamSettings) -> Void) {
        _settings = State(initialValue: settings)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Codec", selection: $settings.codec) {
                        ForEach(DirectVideoCodec.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("H.265 looks sharper at the same bitrate. If the NanoKVM sends no H.265 picture, the console uses H.264 instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Rate control", selection: $settings.rateControl) {
                        Text("As set on the NanoKVM").tag(NanoKVMStreamSettings.RateControl?.none)
                        ForEach(NanoKVMStreamSettings.RateControl.allCases) { mode in
                            Text(mode.displayName).tag(Optional(mode))
                        }
                    }
                    .help("CBR keeps the bitrate steady. VBR saves bandwidth on a still screen.")

                    optionalSlider("Bitrate", value: $settings.bitrate,
                                   range: NanoKVMStreamSettings.bitrateRange, step: 500,
                                   initial: settings.rateControl?.suggestedBitrate ?? 8000) { "\($0) kbps" }
                    optionalSlider("Keyframe interval (GOP)", value: $settings.gop,
                                   range: NanoKVMStreamSettings.gopRange, step: 1, initial: 50) { "\($0) frames" }
                    optionalSlider("Frame rate", value: $settings.fps,
                                   range: NanoKVMStreamSettings.fpsRange, step: 5, initial: 0) { $0 == 0 ? "Auto" : "\($0) fps" }
                } header: {
                    Text("Encoder")
                } footer: {
                    Text("Settings you leave off keep whatever the NanoKVM has now, which is what its web page last set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save and Reconnect") {
                    onSave(settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460)
    }

    /// A toggle that turns a setting on, with a slider for its value.
    @ViewBuilder
    private func optionalSlider(_ title: String, value: Binding<Int?>, range: ClosedRange<Int>, step: Int,
                                initial: Int, label: @escaping (Int) -> String) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue != nil },
                                    set: { value.wrappedValue = $0 ? initial : nil }))
        if let current = value.wrappedValue {
            HStack {
                Slider(value: Binding(get: { Double(current) },
                                      set: { value.wrappedValue = Int(($0 / Double(step)).rounded()) * step }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
                Text(label(min(max(current, range.lowerBound), range.upperBound)))
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }
        }
    }
}
