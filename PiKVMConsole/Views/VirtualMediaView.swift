import PiKVMKit
import SwiftUI
import UniformTypeIdentifiers

/// Manages a PiKVM's virtual drive: pick an image, plug it into the remote
/// machine as a CD/DVD or flash drive, and upload or delete images.
struct VirtualMediaView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let deviceID: UUID

    @State private var selected: String?
    @State private var asCD = true
    @State private var writable = false
    @State private var working = false
    @State private var choosingFile = false
    @State private var imageToDelete: MSDImage?

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private func size(_ bytes: Int64) -> String { Self.sizeFormatter.string(fromByteCount: bytes) }

    var body: some View {
        let session = app.session(for: deviceID)
        VStack(spacing: 0) {
            Group {
                if let msd = session.msd, msd.enabled {
                    form(session, msd)
                } else if session.client == nil {
                    ContentUnavailableView("Not Connected", systemImage: "wifi.slash",
                                           description: Text("Connect to this PiKVM to manage its virtual drive."))
                } else {
                    ContentUnavailableView("No Virtual Drive", systemImage: "opticaldisc",
                                           description: Text("This PiKVM has no virtual drive (Mass Storage) enabled."))
                }
            }
            if let problem = session.mediaError {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
            }
            Divider()
            HStack {
                if let free = session.msd?.freeBytes {
                    Text("\(size(free)) free on the PiKVM").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 540)
        .task { await session.refreshMSD() }
        .onAppear {
            session.mediaError = nil
            adopt(session.msd?.drive)
        }
        .onChange(of: session.msd?.drive) { _, drive in adopt(drive) }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { session.startUpload(fileURL: url) }
        }
        .confirmationDialog("Delete \(imageToDelete?.name ?? "")?",
                            isPresented: Binding(get: { imageToDelete != nil }, set: { if !$0 { imageToDelete = nil } }),
                            presenting: imageToDelete) { image in
            Button("Delete", role: .destructive) { run { try await session.removeImage(image.name) } }
        } message: { _ in
            Text("This removes the image from the PiKVM. The file on your Mac is not affected.")
        }
    }

    @ViewBuilder private func form(_ session: DeviceSession, _ msd: MSDState) -> some View {
        let connected = msd.drive?.connected ?? false
        let chosen = msd.images.first { $0.name == selected }
        let locked = working || msd.busy || session.upload != nil

        Form {
            Section("Drive") {
                LabeledContent("Status") {
                    if connected, let image = msd.drive?.image {
                        Label("\(image.name) is connected as a \(msd.drive?.cdrom == true ? "CD/DVD" : "flash drive")",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Nothing connected").foregroundStyle(.secondary)
                    }
                }
                Picker("Present as", selection: $asCD) {
                    Text("CD/DVD").tag(true)
                    Text("Flash drive").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(connected)
                if !asCD {
                    Toggle("Let the remote machine write to the image", isOn: $writable)
                        .disabled(connected)
                }
                if asCD, let chosen, !chosen.cdromable {
                    Text("This image is too large for this PiKVM to present as a CD/DVD. It will be connected as a flash drive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if connected {
                        Button("Eject") { run { try await session.ejectMedia() } }
                    } else {
                        Button("Connect") {
                            guard let chosen else { return }
                            run { try await session.mountMedia(image: chosen.name, cdrom: asCD && chosen.cdromable, writable: writable) }
                        }
                        .disabled(chosen == nil || chosen?.complete == false)
                    }
                    if working || msd.busy { ProgressView().controlSize(.small) }
                }
                .disabled(locked)
                if session.switchState != nil {
                    Text("The drive goes to whichever Switch port is active.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Images on the PiKVM") {
                if msd.images.isEmpty {
                    Text("No images yet. Upload an ISO or disk image to get started.").foregroundStyle(.secondary)
                }
                ForEach(msd.images) { image in
                    HStack {
                        Image(systemName: selected == image.name ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == image.name ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.name).lineLimit(1).truncationMode(.middle)
                            Text(image.complete ? size(image.size) : "\(size(image.size)) · incomplete")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if image.removable {
                            Button { imageToDelete = image } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(connected || locked)
                                .help(connected ? "Eject the drive before deleting images" : "Delete this image from the PiKVM")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !connected else { return }
                        selected = image.name
                        asCD = image.looksLikeCD && image.cdromable
                    }
                }

                if let upload = session.upload {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Uploading \(upload.name)").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Cancel") { session.cancelUpload() }
                        }
                        ProgressView(value: Double(upload.sent), total: Double(max(upload.total, 1)))
                        Text("\(size(upload.sent)) of \(size(upload.total))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Button { choosingFile = true } label: { Label("Upload Image…", systemImage: "square.and.arrow.up") }
                        .disabled(connected || locked)
                        .help(connected ? "Eject the drive before uploading" : "Copy an ISO or disk image from this Mac to the PiKVM")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Shows what the drive currently holds, unless the user is choosing something else.
    private func adopt(_ drive: MSDState.Drive?) {
        guard let drive else { return }
        if drive.connected || selected == nil, let image = drive.image {
            selected = image.name
            asCD = drive.cdrom
            writable = drive.writable
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        let session = app.session(for: deviceID)
        Task {
            working = true
            defer { working = false }
            session.mediaError = nil
            do {
                try await action()
            } catch {
                session.mediaError = error.localizedDescription
                await session.refreshMSD()
            }
        }
    }
}
