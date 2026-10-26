import SpacerCore
import SwiftUI

/// The sidebar: disks, recent scans, the folder picker and the version.
struct SidebarView: View {
  let session: ScanSession
  let volumes: [VolumeInfo]
  let recents: [URL]
  let onScan: (URL) -> Void
  let onRefreshVolumes: () -> Void
  /// The volume being ejected, if any. Its eject button shows progress and is disabled.
  let ejecting: URL?
  let onEject: (VolumeInfo) -> Void
  @State private var choosingFolder = false

  var body: some View {
    List {
      Section("Disks") {
        ForEach(volumes) { volume in
          let isCurrent = session.scanURL == volume.url
          HStack(spacing: Theme.spacingSM) {
            Button {
              onScan(volume.url)
            } label: {
              DiskRow(volume: volume, finishedAt: isCurrent ? session.finishedAt : nil)
            }
            .buttonStyle(.plain)
            if volume.isEjectable {
              if ejecting == volume.url {
                ProgressView().controlSize(.small)
              }
              // A separate button, not inside the scan button, so a click never scans.
              Button {
                onEject(volume)
              } label: {
                Image(systemName: "eject")
              }
              .buttonStyle(.borderless)
              .disabled(ejecting != nil)
              .help("Eject \(volume.name)")
              .accessibilityLabel("Eject \(volume.name)")
            }
          }
          .contextMenu {
            if volume.isEjectable {
              Button("Eject") { onEject(volume) }
                .disabled(ejecting != nil)
            }
          }
          .listRowBackground(currentBackground(isCurrent))
        }
      }
      if !recents.isEmpty {
        Section("Recent") {
          ForEach(recents, id: \.self) { url in
            Button {
              onScan(url)
            } label: {
              Label(
                url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                systemImage: "clock"
              )
              .font(.system(size: 13))
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url.path)
            .listRowBackground(currentBackground(session.scanURL == url))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: Theme.spacingSM) {
        Button {
          choosingFolder = true
        } label: {
          Label("Choose Folder…", systemImage: "folder.badge.plus")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        Text(
          AppVersion.footerText(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
      }
      .padding(Theme.spacingMD)
    }
    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { onScan(url) }
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
    ) { _ in onRefreshVolumes() }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
    ) { _ in onRefreshVolumes() }
  }

  private func currentBackground(_ isCurrent: Bool) -> some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(Color.accentColor.opacity(isCurrent ? 0.15 : 0))
      .padding(.horizontal, 4)
  }
}

/// A disk: name, used and free, a capacity bar and, for the scanned disk, how old the scan is.
private struct DiskRow: View {
  let volume: VolumeInfo
  let finishedAt: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text(volume.name).font(.system(size: 13)).lineLimit(1)
      } icon: {
        Image(systemName: volume.url.path == "/" ? "internaldrive" : "externaldrive")
          .foregroundStyle(Color.accentColor)
      }
      CapacityBar(fraction: volume.usedFraction)
      Text(volume.usedAndFreeText)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      if let finishedAt {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(ScanAge.text(finished: finishedAt, now: context.date))
            .font(.system(size: 11))
            .foregroundStyle(
              ScanAge.isStale(finished: finishedAt, now: context.date)
                ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// Used space of a volume. Orange when the volume is over 90% full.
private struct CapacityBar: View {
  let fraction: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule()
          .fill(fraction > 0.9 ? Color.orange : Color.accentColor)
          .frame(width: max(4, proxy.size.width * fraction))
      }
    }
    .frame(height: 4)
  }
}
