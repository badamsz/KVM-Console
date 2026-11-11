import PiKVMKit
import SwiftUI
import UniformTypeIdentifiers

/// Manages a PiKVM's or NanoKVM's virtual drive: pick an image, plug it into the remote
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
    @State private var askingForURL = false
    @State private var downloadURL = ""

    /// "PiKVM", "NanoKVM", ... for messages.
    private var deviceName: String { app.device(deviceID)?.model.shortName ?? "PiKVM" }
    private var family: DeviceFamily { app.device(deviceID)?.family ?? .pikvm }

    /// A NanoKVM lists images by their path in /data; show the file name.
    private func displayName(_ image: MSDImage) -> String {
        family.isSipeed ? (image.name as NSString).lastPathComponent : image.name
    }

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
                } else if !session.isConnected {
                    ContentUnavailableView("Not Connected", systemImage: "wifi.slash",
                                           description: Text("Connect to this \(deviceName) to manage its virtual drive."))
                } else {
                    ContentUnavailableView("No Virtual Drive", systemImage: "opticaldisc",
                                           description: Text("This \(deviceName) has no virtual drive (Mass Storage) enabled."))
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
                HelpButton(topic: "virtual-media")
                if let free = session.msd?.freeBytes {
                    Text("\(size(free)) free on the \(deviceName)").foregroundStyle(.secondary).font(.callout)
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
        .alert("Download from URL", isPresented: $askingForURL) {
            TextField("https://example.com/image.iso", text: $downloadURL)
            Button("Download") {
                let text = downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", url.host != nil else {
                    session.mediaError = "That isn't a web address. Use one that starts with https://."
                    return
                }
                run { try await session.startDownload(url: url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(deviceName) downloads the .iso or .img file itself, so it needs internet access. You can close this window while it runs.")
        }
        .confirmationDialog("Delete \(imageToDelete.map(displayName) ?? "")?",
                            isPresented: Binding(get: { imageToDelete != nil }, set: { if !$0 { imageToDelete = nil } }),
                            presenting: imageToDelete) { image in
            Button("Delete", role: .destructive) { run { try await session.removeImage(image.name) } }
        } message: { _ in
            Text("This removes the image from the \(deviceName). The file on your Mac is not affected.")
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
                        Label("\(displayName(image)) is connected as a \(msd.drive?.cdrom == true ? "CD/DVD" : "flash drive")",
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
                if !asCD, family != .nanoKVM {
                    Toggle("Let the remote machine write to the image", isOn: $writable)
                        .disabled(connected)
                }
                if asCD, let chosen, !chosen.cdromable {
                    Text(family.isSipeed
                         ? "This isn't an ISO 9660 or UDF disc image, so it will be connected as a flash drive."
                         : "This image is too large for this PiKVM to present as a CD/DVD. It will be connected as a flash drive.")
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

            Section("Images on the \(deviceName)") {
                if msd.images.isEmpty {
                    Text("No images yet. Upload an ISO or disk image to get started.").foregroundStyle(.secondary)
                }
                ForEach(msd.images) { image in
                    HStack {
                        Image(systemName: selected == image.name ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == image.name ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(image)).lineLimit(1).truncationMode(.middle)
                            if image.size > 0 || !image.complete {
                                Text(image.complete ? size(image.size) : "\(size(image.size)) · incomplete")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if image.removable {
                            Button { imageToDelete = image } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(connected || locked)
                                .help(connected ? "Eject the drive before deleting images" : "Delete this image from the \(deviceName)")
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
                } else if !session.supportsImageUpload {
                    Text("Uploading from this Mac needs NanoKVM 2.5.3 or newer. Update the NanoKVM, download an image from a URL, or copy one with scp to /data.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button { choosingFile = true } label: { Label("Upload Image…", systemImage: "square.and.arrow.up") }
                        .disabled(connected || locked || session.download != nil)
                        .help(connected ? "Eject the drive before uploading" : "Copy an ISO or disk image from this Mac to the \(deviceName)")
                }

                if let download = session.download {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Downloading \(URL(string: download.file ?? "")?.lastPathComponent ?? "image")")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if session.nanoClient?.canCancelDownload == true {
                                Button("Cancel") { run { try await session.cancelDownload() } }
                            }
                        }
                        if let fraction = download.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        if let loaded = download.loaded, loaded > 0 {
                            Text((download.total ?? 0) > 0 ? "\(size(loaded)) of \(size(download.total ?? 0))" : size(loaded))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } else if session.supportsURLDownload {
                    Button { downloadURL = ""; askingForURL = true } label: {
                        Label("Download from URL…", systemImage: "link")
                    }
                    .disabled(connected || locked)
                    .help("Have the \(deviceName) download an ISO or disk image from the internet itself")
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
