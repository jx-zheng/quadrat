import AppKit
import SwiftUI
import QuadratCore

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            QuadratTheme.window(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                if model.phase == .picker {
                    titleBar
                }
                if model.phase == .picker {
                    DiskPickerView(model: model)
                } else {
                    WorkspaceView(model: model)
                }
            }
            if model.showAccess {
                Color.black.opacity(scheme == .dark ? 0.45 : 0.18).ignoresSafeArea()
                FullDiskAccessCard(model: model)
            }
        }
        .frame(minWidth: model.demoFrame ? 1600 : 960, minHeight: model.demoFrame ? 1000 : 640)
        .onAppear { model.installKeyMonitor() }
        .onDisappear { model.removeKeyMonitor() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            if model.drawsTrafficLights {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0xFF5F57)).frame(width: 12, height: 12)
                    Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 12, height: 12)
                    Circle().fill(Color(hex: 0x28C840)).frame(width: 12, height: 12)
                }
                .padding(.leading, 4)
            } else {
                Color.clear.frame(width: 68, height: 12)
            }
            if model.phase == .picker {
                Text("Quadrat")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: model.phase == .picker ? 28 : 0)
    }
}

struct DiskPickerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)
            AppMark(side: 72)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            VStack(spacing: 6) {
                Text("Which disk should Quadrat map?")
                    .font(.system(size: 26, weight: .bold))
                Text("Quadrat reads file sizes only. Nothing is uploaded, and nothing changes until you ask.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(model.volumes) { volume in
                    DiskCard(volume: volume, selected: volume.id == model.selectedVolumeID) {
                        model.choose(volume)
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                Button {
                    model.requestScan()
                } label: {
                    Text(model.selectedVolume.map { "Scan \($0.name)" } ?? "Scan")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedVolume?.isNetwork ?? true)
                .keyboardShortcut(.defaultAction)
            }
            Text("Tip: drop any folder on the Dock icon to map just that folder.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Map"
        if panel.runModal() == .OK, let url = panel.url {
            model.scanFolder(url)
        }
    }
}

struct DiskCard: View {
    var volume: DiskVolume
    var selected: Bool
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: volume.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(volume.isNetwork ? Color.secondary : Color.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(volume.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(volume.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if selected && !volume.isNetwork {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                usageBar
                HStack {
                    Text(volume.isNetwork ? "\(ByteFormat.bytes(volume.used)) used" : "\(ByteFormat.bytes(volume.used)) used")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(ByteFormat.bytes(volume.free)) free of \(ByteFormat.bytes(volume.capacity))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if volume.isNetwork {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                        Text("Network volumes aren't scanned")
                    } else if let date = volume.lastScanned {
                        Text(lastScanned(date))
                    } else {
                        Text("Never scanned")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 248, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected && !volume.isNetwork ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected && !volume.isNetwork ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(volume.isNetwork)
        .opacity(volume.isNetwork ? 0.72 : 1)
        .accessibilityLabel("\(volume.name), \(volume.detail), \(ByteFormat.bytes(volume.used)) used")
    }

    private var usageBar: some View {
        GeometryReader { geo in
            let fraction = volume.capacity > 0 ? min(1, Double(volume.used) / Double(volume.capacity)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(volume.isNetwork ? Color.secondary.opacity(0.45) : Color.accentColor)
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
        .padding(.top, 4)
    }

    private func lastScanned(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInYesterday(date) { return "Last scanned yesterday, \(time)" }
        if Calendar.current.isDateInToday(date) { return "Last scanned today, \(time)" }
        return "Last scanned \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct FullDiskAccessCard: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 36, height: 36)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Full Disk Access to see everything")
                        .font(.system(size: 16, weight: .semibold))
                    Text("macOS hides Mail, Messages, Safari, Photos internals, other apps' containers and Time Machine data from apps without Full Disk Access. Without it, Quadrat still maps the rest and marks what it couldn't read.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("PRIVACY & SECURITY › FULL DISK ACCESS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    AppMark(side: 22)
                    Text("Quadrat").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Capsule().fill(Color.accentColor).frame(width: 32, height: 18)
                        .overlay(alignment: .trailing) {
                            Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                        }
                        .accessibilityLabel("Quadrat enabled")
                }
                VStack(alignment: .leading, spacing: 3) {
                    step(1, "Click ", bold: "Open System Settings", rest: ".")
                    step(2, "Turn on ", bold: "Quadrat", rest: " and authenticate.")
                    Text("3. Come back. Quadrat notices on its own, with no relaunch.")
                }
                .font(.system(size: 12))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))

            if model.accessWaiting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Continue with Limited Access") { model.continueLimited() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") { model.openAccessSettings() }
                    .buttonStyle(.borderedProminent)
            }
            Text(FullDiskAccess.settingsURL.absoluteString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(22)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color.white)
                .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Allow Full Disk Access to see everything")
    }

    private func step(_ n: Int, _ prefix: String, bold: String, rest: String) -> Text {
        Text("\(n). \(prefix)") + Text(bold).bold() + Text(rest)
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.phase == .scanning {
                scanProgress
            }
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 228)
                Rectangle().fill(QuadratTheme.separator(scheme)).frame(width: 1)
                VStack(spacing: 0) {
                    breadcrumb
                    Rectangle().fill(QuadratTheme.separator(scheme)).frame(height: 1)
                    ZStack(alignment: .bottom) {
                        treemap
                        if model.selection != nil && model.phase == .map {
                            selectionBar
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                        if model.showTrash {
                            Color.black.opacity(0.25)
                            TrashCard(model: model)
                        }
                    }
                    if model.phase == .map {
                        legend
                    } else {
                        scanFooter
                    }
                }
            }
        }
        .onAppear { model.rebuildPicture() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if !model.drawsTrafficLights {
                Color.clear.frame(width: 62)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0xFF5F57)).frame(width: 12, height: 12)
                    Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 12, height: 12)
                    Circle().fill(Color(hex: 0x28C840)).frame(width: 12, height: 12)
                }
            }
            Button { model.zoomOut() } label: { Text("‹").font(.system(size: 16, weight: .semibold)) }
                .disabled(!model.isZoomed)
                .accessibilityLabel("Back")
            Button { model.zoomForward() } label: { Text("›").font(.system(size: 16, weight: .semibold)) }
                .disabled(model.forwardStack.isEmpty)
                .accessibilityLabel("Forward")
            VStack(spacing: 1) {
                Text(model.phase == .scanning ? (model.activeVolume?.name ?? "Scanning") : currentTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                metricButton("On Disk", .allocated)
                metricButton("Logical", .logical)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            .accessibilityLabel("Size metric")
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .frame(width: 180, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .onSubmit { model.findSearch() }
            if model.phase == .scanning {
                Button("Stop") { model.stopScan() }
                    .buttonStyle(.bordered)
            } else {
                Button("Rescan") { model.rescan() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rescan")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.55))
    }

    private func metricButton(_ title: String, _ metric: SizeMetric) -> some View {
        let selected = model.metric == metric
        return Button(title) { model.setMetric(metric) }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(title)
    }

    private var currentTitle: String {
        if !model.isZoomed, let name = model.activeVolume?.name, !name.isEmpty { return name }
        guard model.store.rootID != 0 else { return "Quadrat" }
        return model.store.name(of: model.zoomID)
    }

    private var subtitle: String {
        if model.phase == .scanning {
            let readout = model.progressOverride
            let items = readout?.items ?? model.stats.items
            let rate = readout?.rate ?? model.stats.itemsPerSecond
            return "Scanning… \(ByteFormat.grouped(UInt64(items))) items · \(ByteFormat.rate(rate))"
        }
        if !model.isZoomed, let volume = model.activeVolume, volume.capacity > 0 {
            return "\(ByteFormat.bytes(volume.used)) used · \(ByteFormat.percent(volume.used, of: volume.capacity)) · \(ByteFormat.bytes(volume.free)) free"
        }
        let bytes = model.store.rootID == 0 ? 0 : model.nodeBytes(model.zoomID)
        let whole = model.activeVolume?.capacity ?? bytes
        return "\(ByteFormat.bytes(bytes)) · \(ByteFormat.percent(bytes, of: max(whole, 1))) of disk"
    }

    private var scanProgress: some View {
        let readout = model.progressOverride
        let scanned = readout?.scanned ?? model.scanFraction?.scanned ?? 0
        let total = readout?.total ?? model.scanFraction?.used ?? 1
        let fraction = total > 0 ? min(1, Double(scanned) / Double(total)) : 0
        return VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.06))
                    Rectangle().fill(Color.accentColor).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)
            HStack {
                Text("\(ByteFormat.bytes(scanned)) of \(ByteFormat.bytes(total)) used space")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(ByteFormat.grouped(UInt64(readout?.items ?? model.stats.items))) items · \(ByteFormat.rate(readout?.rate ?? model.stats.itemsPerSecond)) · \(readout?.skipped ?? model.stats.inaccessible) skipped")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(readout?.path ?? model.stats.currentPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420, alignment: .trailing)
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 4)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(model.mapBreadcrumb)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("Click to zoom")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("Space")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text("Quick Look")
                .foregroundStyle(.secondary)
            if model.isZoomed {
                Button { model.revealSelection() } label: {
                    Label("Enclosing folder", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var treemap: some View {
        GeometryReader { geo in
            let picture = model.picture
            ZStack(alignment: .topLeading) {
                TreemapHost(
                    picture: picture,
                    scheme: scheme,
                    hover: model.hover,
                    onHover: { id in
                        let next = (id == nil || id == model.zoomID) ? nil : id
                        if model.hover != next { model.hover = next }
                    },
                    onClick: { point in
                        model.click(at: point)
                    }
                )
                if picture.hatch.width > 2 {
                    HatchOverlay(
                        rect: picture.hatch,
                        title: "Not scanned yet",
                        detail: ByteFormat.bytes(picture.unscannedBytes),
                        scheme: scheme
                    )
                }
                if let hover = model.hover, model.phase != .picker, !model.showTrash, let tile = picture.tiles.first(where: { $0.id == hover }) {
                    TooltipCard(model: model, id: hover)
                        .position(tooltipPosition(tile: tile, in: geo.size))
                }
            }
            .onAppear { model.updateViewport(geo.size) }
            .onChange(of: geo.size) { _, newSize in model.updateViewport(newSize) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(treemapAccessLabel)
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: "Zoom in") { if let id = model.selection { model.zoom(into: id) } }
            .accessibilityAction(named: "Zoom out") { model.zoomOut() }
            .accessibilityAction(named: "Reveal in Finder") { model.revealSelection() }
            .accessibilityAction(named: "Move to Trash") { model.askTrash() }
        }
        .background(QuadratTheme.canvas(scheme))
    }

    private var treemapAccessLabel: String {
        let title = model.store.rootID == 0 ? "Treemap" : model.store.name(of: model.zoomID)
        if let hover = model.hover {
            return "\(title). \(model.displayName(of: hover)), \(ByteFormat.bytes(model.nodeBytes(hover)))"
        }
        return "Treemap of \(title). Click a folder to zoom."
    }

    private func tooltipPosition(tile: TileDraw, in size: CGSize) -> CGPoint {
        let x = min(size.width - 150, max(150, tile.x + tile.width / 2))
        let y = min(size.height - 70, max(70, tile.y + tile.height * 0.72))
        return CGPoint(x: x, y: y)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(QuadratTheme.legendOrder, id: \.rawValue) { kind in
                HStack(spacing: 5) {
                    Circle().fill(QuadratTheme.kind(kind, scheme)).frame(width: 8, height: 8)
                    Text(kind.legendTitle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(ByteFormat.grouped(model.itemCountOverride ?? UInt64(model.store.rootID == 0 ? 0 : model.store.itemCount[Int(model.store.rootID)]))) items")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(scheme == .dark ? Color.black.opacity(0.2) : Color.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Colour legend")
    }

    private var scanFooter: some View {
        HStack {
            Text("\(min(8, ProcessInfo.processInfo.activeProcessorCount)) workers · getattrlistbulk")
            Text("Layout refreshes 4×/s while scanning")
            Text("Sizes so far are lower bounds")
            Spacer()
            Text("\(ByteFormat.grouped(UInt64(model.progressOverride?.items ?? model.stats.items))) items so far")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            if let id = model.selection {
                Image(systemName: model.store.isDirectory(id) ? "folder.fill" : "doc.fill")
                    .foregroundStyle(QuadratTheme.kind(model.store.kind(id), scheme))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.displayName(of: id))  \(ByteFormat.bytes(model.nodeBytes(id))) · \(ByteFormat.percent(model.nodeBytes(id), of: model.activeVolume?.capacity ?? model.nodeBytes(model.store.rootID))) of disk · \(itemPhrase(id))")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(model.path(of: id))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { model.revealSelection() } label: { Label("Reveal in Finder", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered)
                Button { model.askTrash() } label: { Label("Move to Trash…", systemImage: "trash") }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!model.canTrash(id))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private func itemPhrase(_ id: UInt32) -> String {
        if model.store.isDirectory(id) || model.store.flags(id).contains(.foldedAggregate) {
            return "\(ByteFormat.grouped(UInt64(model.store.itemCount[Int(id)]))) items"
        }
        return "file"
    }
}

struct TreemapHost: NSViewRepresentable {
    var picture: MapPicture
    var scheme: ColorScheme
    var hover: UInt32?
    var onHover: (UInt32?) -> Void
    var onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> TreemapMapView {
        let view = TreemapMapView(frame: .zero)
        view.backingScale = 2
        return view
    }

    func updateNSView(_ view: TreemapMapView, context: Context) {
        view.onHoverID = onHover
        view.onClick = onClick
        view.backingScale = 2
        view.show(picture: picture, scheme: scheme)
        view.highlight(id: hover)
    }
}

struct TreemapCanvas: View, Equatable {
    var picture: MapPicture
    var scheme: ColorScheme

    static func == (lhs: TreemapCanvas, rhs: TreemapCanvas) -> Bool {
        lhs.picture == rhs.picture && lhs.scheme == rhs.scheme
    }

    var body: some View {
        Canvas { context, size in
            let canvas = QuadratTheme.canvas(scheme)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(canvas))
            for tile in picture.tiles {
                let rect = CGRect(x: tile.x, y: tile.y, width: max(0, tile.width), height: max(0, tile.height))
                guard rect.width >= 1, rect.height >= 1 else { continue }
                let radius = min(5, max(2, min(rect.width, rect.height) / 4))
                let fill = QuadratTheme.varied(tile.kind, scheme, variant: tile.id)
                if tile.hasChildren, tile.header > 0 {
                    let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(tile.header, rect.height))
                    let barPath = Path(roundedRect: bar, cornerRadius: min(4, bar.height / 2))
                    context.fill(barPath, with: .color(fill.opacity(scheme == .dark ? 0.55 : 0.72)))
                } else if !tile.hasChildren {
                    let path = Path(roundedRect: rect, cornerRadius: radius)
                    context.fill(path, with: .color(fill))
                    if tile.hatched {
                        var clip = context
                        clip.clip(to: path)
                        drawHatch(clip, rect: rect, color: Color.white.opacity(scheme == .dark ? 0.18 : 0.28))
                    } else if tile.isDepthCapped {
                        drawDepthHint(context, rect: rect, path: path, scheme: scheme)
                    }
                }
                guard tile.showsLabel else { continue }
                let label = LabelPlacement.frame(
                    tileX: tile.x, tileY: tile.y, tileWidth: tile.width, tileHeight: tile.height, header: tile.header
                )
                let name = tile.name
                if name.isEmpty { continue }
                let band = CGRect(x: label.x, y: label.y, width: label.width, height: max(label.height, tile.header > 0 ? tile.header - 2 : 28))
                context.drawLayer { layer in
                    layer.clip(to: Path(roundedRect: rect, cornerRadius: radius))
                    layer.clip(to: Path(band))
                    if tile.header > 0 {
                        let line = Text("\(name)  \(tile.sizeText)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(scheme == .dark ? Color.white : Color.white)
                        layer.draw(line, at: CGPoint(x: band.minX, y: band.minY + 1), anchor: .topLeading)
                    } else {
                        let title = Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        layer.draw(title, at: CGPoint(x: band.minX, y: band.minY), anchor: .topLeading)
                        if band.height >= 28 {
                            let size = Text(tile.sizeText).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                            layer.draw(size, at: CGPoint(x: band.minX, y: band.minY + 15), anchor: .topLeading)
                        }
                    }
                }
            }
        }
    }

    private func drawDepthHint(_ context: GraphicsContext, rect: CGRect, path: Path, scheme: ColorScheme) {
        guard rect.width >= 56, rect.height >= 40 else { return }
        var clip = context
        clip.clip(to: path)
        let insetX = min(12, rect.width * 0.1)
        let insetY = min(12, rect.height * 0.14)
        let inner = rect.insetBy(dx: insetX, dy: insetY)
        guard inner.width > 12, inner.height > 10 else { return }
        let columns = inner.width > inner.height * 1.3 ? 3 : 2
        let rows = 2
        let gap = 3.0
        let blockW = (inner.width - gap * Double(columns - 1)) / Double(columns)
        let blockH = (inner.height - gap * Double(rows - 1)) / Double(rows)
        let tint = Color.white.opacity(scheme == .dark ? 0.14 : 0.32)
        for row in 0..<rows {
            for column in 0..<columns {
                let block = CGRect(
                    x: inner.minX + Double(column) * (blockW + gap),
                    y: inner.minY + Double(row) * (blockH + gap),
                    width: blockW,
                    height: blockH
                )
                clip.fill(Path(roundedRect: block, cornerRadius: 2), with: .color(tint))
            }
        }
    }

    private func drawHatch(_ context: GraphicsContext, rect: CGRect, color: Color) {
        var clip = context
        clip.clip(to: Path(rect))
        var x = rect.minX - rect.height
        while x < rect.maxX {
            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            clip.stroke(path, with: .color(color), lineWidth: 1)
            x += 7
        }
    }
}

struct HatchOverlay: View {
    var rect: CGRect
    var title: String
    var detail: String
    var scheme: ColorScheme

    var body: some View {
        Canvas { context, _ in
            let path = Path(rect)
            context.fill(path, with: .color(scheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color(red: 0.93, green: 0.93, blue: 0.93)))
            var clip = context
            clip.clip(to: path)
            let color = scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
            var x = rect.minX - rect.height
            while x < rect.maxX + rect.height {
                var line = Path()
                line.move(to: CGPoint(x: x, y: rect.maxY))
                line.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                clip.stroke(line, with: .color(color), lineWidth: 8)
                x += 14
            }
            let label = Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(scheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.55))
            let sub = Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: rect.minX + 16, y: rect.minY + 16), anchor: .topLeading)
            context.draw(sub, at: CGPoint(x: rect.minX + 16, y: rect.minY + 36), anchor: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("\(title), \(detail)")
    }
}

struct HoverOutline: View {
    var tile: TileDraw
    var scheme: ColorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(scheme == .dark ? Color.white : Color.black, lineWidth: 2)
            .frame(width: tile.width, height: tile.height)
            .position(x: tile.x + tile.width / 2, y: tile.y + tile.height / 2)
            .allowsHitTesting(false)
    }
}

struct TooltipCard: View {
    @ObservedObject var model: AppModel
    var id: UInt32
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let bytes = model.nodeBytes(id)
        let capacity = model.activeVolume?.capacity ?? bytes
        let used = model.activeVolume?.used ?? model.nodeBytes(model.store.rootID)
        let flags = model.store.flags(id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(QuadratTheme.kind(model.store.kind(id), scheme)).frame(width: 8, height: 8)
                Text(model.displayName(of: id))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(TileFold.isRemainder(id) ? "Items too small to draw on their own" : model.path(of: id))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(ByteFormat.bytes(bytes))
                .font(.system(size: 22, weight: .semibold))
            HStack(spacing: 8) {
                Text("\(ByteFormat.percent(bytes, of: max(capacity, 1))) of disk")
                Text("\(ByteFormat.percent(bytes, of: max(used, 1))) of used")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Text(detail(flags))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ flags: NodeFlags) -> String {
        if TileFold.isRemainder(id) {
            return "\(model.displayName(of: id)) · folded together"
        }
        if model.store.isDirectory(id) {
            let items = ByteFormat.grouped(UInt64(model.store.itemCount[Int(id)]))
            let bound = flags.contains(.lowerBound) ? "≥ " : ""
            return "\(bound)\(items) items · folder"
        }
        if flags.contains(.foldedAggregate) {
            return "\(ByteFormat.grouped(UInt64(model.store.itemCount[Int(id)]))) files folded together"
        }
        var bits = ["File"]
        let logical = model.store.bytes(id, .logical)
        let alloc = model.store.bytes(id, .allocated)
        if flags.contains(.sparse) || logical > alloc + alloc / 10 {
            bits.append("logical \(ByteFormat.bytes(logical)) (sparse)")
        }
        if flags.contains(.hardLinkDuplicate) { bits.append("hard link, not counted twice") }
        if flags.contains(.mayShareBlocks) { bits.append("may include shared cloned data") }
        if flags.contains(.symlink) { bits.append("symbolic link") }
        return bits.joined(separator: " · ")
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Disks")
            ForEach(model.volumes) { volume in
                sidebarRow(
                    symbol: volume.symbol,
                    title: volume.name,
                    trailing: volume.isNetwork ? "Network" : (model.phase == .scanning && volume.id == model.activeVolume?.id ? "Scanning…" : ByteFormat.bytes(volume.isStartup ? (model.activeVolume?.used ?? volume.used) : volume.used)),
                    selected: volume.id == (model.activeVolume?.id ?? model.selectedVolumeID)
                ) {
                    model.choose(volume)
                    if model.phase == .picker { model.requestScan() }
                }
                .disabled(volume.isNetwork)
            }
            section("Jump To")
                .padding(.top, 8)
            jump("Home", "house", "you")
            jump("Library/Developer", "hammer", "Developer")
            jump("~/Developer", "folder", "Developer")
            jump("Downloads", "arrow.down.circle", "Downloads")
            Spacer()
            if let volume = model.activeVolume ?? model.selectedVolume, !volume.isNetwork {
                volumeFooter(volume)
            }
        }
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        .background(QuadratTheme.sidebar(scheme))
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func jump(_ title: String, _ symbol: String, _ needle: String) -> some View {
        sidebarRow(symbol: symbol, title: title, trailing: jumpSize(needle), selected: false) {
            model.jump(to: needle == "you" ? "you" : needle)
        }
    }

    private func jumpSize(_ needle: String) -> String {
        guard model.store.rootID != 0 else { return "" }
        let match = model.store.largestDescendant(under: model.store.rootID) {
            model.store.name(of: $0).caseInsensitiveCompare(needle) == .orderedSame
        }
        guard let match else { return "" }
        return ByteFormat.bytes(model.nodeBytes(match))
    }

    private func sidebarRow(symbol: String, title: String, trailing: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                Spacer(minLength: 4)
                Text(trailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(trailing)")
    }

    private func volumeFooter(_ volume: DiskVolume) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(volume.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(ByteFormat.bytes(volume.free)) free")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let fraction = volume.capacity > 0 ? min(1, Double(volume.used) / Double(volume.capacity)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)
            footerLine("Used (volume)", ByteFormat.bytes(volume.used))
            footerLine("Purgeable", ByteFormat.bytes(volume.purgeable))
            footerLine("Local snapshots", model.drawsTrafficLights ? ByteFormat.bytes(DemoDisk.snapshots) : (volume.snapshotCount > 0 ? "\(volume.snapshotCount)" : "None"))
            footerLine("Capacity", ByteFormat.bytes(volume.capacity))
            HStack {
                let count = model.inaccessibleOverride ?? model.stats.inaccessible
                Label("\(count) inaccessible", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Spacer()
                if let elapsed = model.elapsedOverride ?? (model.phase == .map ? model.stats.elapsed : nil) {
                    Text("\(Int(elapsed.rounded())) s")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .help(model.stats.currentPath)
            .accessibilityLabel("\(model.inaccessibleOverride ?? model.stats.inaccessible) inaccessible items")
        }
        .padding(12)
    }

    private func footerLine(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

struct TrashCard: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let id = model.selection ?? 0
        let name = model.store.rootID == 0 ? "" : model.store.name(of: id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 36, height: 36)
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move “\(name)” to the Trash?")
                        .font(.system(size: 15, weight: .semibold))
                    Text(summary(id))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(model.store.rootID == 0 ? "" : model.path(of: id))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            Text(caveat(id))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.trashError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.showTrash = false }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") { model.confirmTrash() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : Color.white)
                .shadow(radius: 24, y: 10)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Move \(name) to the Trash?")
    }

    private func summary(_ id: UInt32) -> String {
        guard model.store.rootID != 0, id != 0 else { return "" }
        let bytes = ByteFormat.bytes(model.nodeBytes(id))
        if model.store.isDirectory(id) {
            let items = ByteFormat.grouped(UInt64(model.store.itemCount[Int(id)]))
            return "\(bytes) in \(items) items. You can put it back from the Trash until you empty it."
        }
        return "\(bytes). You can put it back from the Trash until you empty it."
    }

    private func caveat(_ id: UInt32) -> String {
        let freed = model.store.rootID == 0 ? 0 : model.store.freedIfDeleted(id)
        let shares = model.store.flags(id).contains(.mayShareBlocks)
        if shares {
            return "About \(ByteFormat.bytes(freed)) would be freed. Space comes back when the Trash is emptied. Files that are APFS clones of other files may free less than shown."
        }
        return "Space comes back when the Trash is emptied. Files that are APFS clones of other files may free less than shown."
    }
}
