import SwiftUI
import AppKit

// Holds a weak reference to the backing NSScrollView so we can programmatically
// set the scroll offset for zoom-around-cursor.
@MainActor
private final class ScrollController {
    weak var scrollView: NSScrollView?

    var contentOffsetX: CGFloat {
        scrollView?.contentView.bounds.origin.x ?? 0
    }

    func scrollToX(_ x: CGFloat) {
        guard let sv = scrollView else { return }
        let maxX = max(0, (sv.documentView?.frame.width ?? 0) - sv.contentSize.width)
        let clamped = min(max(x, 0), maxX)
        sv.contentView.scroll(to: NSPoint(x: clamped, y: 0))
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// Returns the mouse X position within the scroll view's visible area.
    func mouseXInViewport(locationInWindow: CGPoint) -> CGFloat? {
        guard let sv = scrollView else { return nil }
        let pt = sv.convert(locationInWindow, from: nil)
        let visibleWidth = sv.contentSize.width
        guard pt.x >= 0, pt.x <= visibleWidth else { return nil }
        return pt.x
    }
}

// Placed inside the ScrollView so it can walk up to the NSScrollView ancestor.
private struct ScrollViewFinder: NSViewRepresentable {
    let controller: ScrollController
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            var v: NSView? = nsView
            while let parent = v?.superview {
                if let sv = parent as? NSScrollView {
                    controller.scrollView = sv
                    return
                }
                v = parent
            }
        }
    }
}

private struct DragSelection {
    var segmentType: SegmentType
    var anchorMs: Int
    var currentMs: Int
    var startMs: Int { min(anchorMs, currentMs) }
    var endMs: Int { max(anchorMs, currentMs) }
}

private enum HandleEdge { case start, end }

private struct HandleDragState {
    var segmentType: SegmentType
    var draftIndex: Int
    var edge: HandleEdge
    var initialX: CGFloat
}

private struct SegmentMoveDragState {
    var sourceSegmentType: SegmentType
    var sourceDraftIndex: Int
    var sourceStartMs: Int
    var sourceEndMs: Int
    var anchorStartX: CGFloat
    var anchorEndX: CGFloat
    var currentStartMs: Int
    var currentEndMs: Int
    var targetSegmentType: SegmentType
}

struct TimelineView: View {
    var durationMs: Int
    var videoDurationMs: Int
    var currentTimeMs: Int
    var zoom: Binding<Double>
    var minimumZoom: Double
    var serverSegments: [SegmentType: [SegmentRange]]
    var drafts: [SegmentType: [SegmentDraft]]
    var autoRecapDraftKeys: Set<String> = []
    var noSegmentFlags: [SegmentType: Bool] = [:]
    var audioTrack: TimelineDensityTrack
    var isAutoRecapEnabled: Bool = false
    var hasSubtitleSourceConfigured: Bool = false
    var onToggleAutoRecap: () -> Void = {}
    var isSceneDetectionEnabled: Bool = true
    var onToggleSceneDetection: () -> Void = {}
    var isMusicLikelihoodEnabled: Bool = true
    var onToggleMusicLikelihood: () -> Void = {}
    var isSubmissionLoggingEnabled: Bool = true
    var onToggleSubmissionLogging: () -> Void = {}
    var onSeek: (Int) -> Void
    var onSegmentDragSelect: (SegmentType, Int, Int) -> Void
    var onDraftStartDrag: (SegmentType, Int, Int) -> Void
    var onDraftEndDrag: (SegmentType, Int, Int) -> Void
    var onDraftMove: (SegmentType, Int, SegmentType, Int, Int) -> Void
    var onDraftHandleDragBegan: () -> Void = {}
    var onDraftHandleDragEnded: () -> Void = {}
    var onMinimumZoomComputed: (Double) -> Void
    var videoLoadID: Int
    var draftOutlineOnly: Bool = false

    private let rowHeight: CGFloat = 28
    private let densityRowHeight: CGFloat = 28
    @State private var viewportWidth: CGFloat = 900
    @State private var isPointerInsideTimeline = false
    @State private var scrollMonitor: Any?
    @State private var currentMinimumZoom: Double = 1.0
    @State private var scrollController = ScrollController()
    @State private var dragSelection: DragSelection? = nil
    @State private var handleDragState: HandleDragState? = nil
    @State private var segmentMoveDragState: SegmentMoveDragState? = nil
    @State private var showHelpPopover = false
    private let handleGrabWidth: CGFloat = 14
    private let labelColumnWidth: CGFloat = 92

    /// Pre-computed row index for each SegmentType so the O(n) firstIndex scan
    /// is never called during rendering or drag hit-testing.
    private static let segmentRowIndex: [SegmentType: Int] = Dictionary(
        uniqueKeysWithValues: SegmentType.allCases.enumerated().map { ($1, $0) }
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Text("Timeline")
                        .font(.headline)

                    Button {
                        showHelpPopover.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .help("Show timeline shortcuts and interactions")
                    .popover(isPresented: $showHelpPopover, arrowEdge: .bottom) {
                        TimelineHelpPopover()
                            .padding(12)
                    }

                    Divider()
                        .frame(height: 14)
                        .padding(.leading, 12)

                    Button {
                        onToggleAutoRecap()
                    } label: {
                        Image(systemName: isAutoRecapEnabled ? "waveform.badge.magnifyingglass" : "waveform.badge.magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(isAutoRecapEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .opacity((!hasSubtitleSourceConfigured && !isAutoRecapEnabled) ? 0.4 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .help(isAutoRecapEnabled ? "Auto Recap enabled – click to disable" : "Auto Recap disabled – click to enable")
                    .disabled(!hasSubtitleSourceConfigured && !isAutoRecapEnabled)

                    Button {
                        onToggleSceneDetection()
                    } label: {
                        Image(systemName: "film.stack")
                            .font(.subheadline)
                            .foregroundStyle(isSceneDetectionEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help(isSceneDetectionEnabled ? "Scene detection enabled – click to disable" : "Scene detection disabled – click to enable")

                    Button {
                        onToggleMusicLikelihood()
                    } label: {
                        Image(systemName: "music.note")
                            .font(.subheadline)
                            .foregroundStyle(isMusicLikelihoodEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help(isMusicLikelihoodEnabled ? "Music likelihood enabled – click to disable" : "Music likelihood disabled – click to enable")

                    Button {
                        onToggleSubmissionLogging()
                    } label: {
                        Image(systemName: "text.append")
                            .font(.subheadline)
                            .foregroundStyle(isSubmissionLoggingEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help(isSubmissionLoggingEnabled ? "Submission log enabled – click to disable" : "Submission log disabled – click to enable")
                }
                Spacer()
                Text("Playhead \(TimeFormatting.display(ms: currentTimeMs))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: clampedZoomBinding,
                    in: minimumZoom...8,
                    step: 0.25
                )
                .frame(width: 180)
                Text(String(format: "%.2fx", zoom.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .frame(width: 46)
            }

            HStack(alignment: .top, spacing: 0) {
                labelColumn
                    .frame(width: labelColumnWidth, height: totalHeight)

                ScrollView(.horizontal) {
                    let width = timelineWidth(durationMs: durationMs, zoom: zoom.wrappedValue)

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: width, height: totalHeight)

                        ForEach(Array(densityTracks.enumerated()), id: \.offset) { index, track in
                            let y = CGFloat(index) * densityRowHeight
                            densityRow(track: track, yOffset: y, width: width)
                        }

                        let segmentTopOffset = densityTracksHeight

                        ForEach(Array(SegmentType.allCases.enumerated()), id: \.element) { index, segmentType in
                            let y = segmentTopOffset + CGFloat(index) * rowHeight

                            Rectangle()
                                .fill(Color.black.opacity(0.05))
                                .frame(width: width, height: rowHeight)
                                .offset(y: y)

                            if noSegmentFlags[segmentType] == true {
                                Canvas { ctx, size in
                                    let spacing: CGFloat = 8
                                    var path = Path()
                                    var x: CGFloat = -size.height
                                    while x < size.width + size.height {
                                        path.move(to: CGPoint(x: x, y: 0))
                                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                                        x += spacing
                                    }
                                    ctx.stroke(path, with: .color(.gray.opacity(0.38)), lineWidth: 1.0)
                                }
                                .frame(width: width, height: rowHeight)
                                .offset(y: y)
                                .allowsHitTesting(false)
                            }

                            ForEach(Array((serverSegments[segmentType] ?? []).enumerated()), id: \.offset) { _, range in
                                segmentBar(
                                    range: range,
                                    segmentType: segmentType,
                                    yOffset: y,
                                    width: width,
                                    isDraft: false
                                )
                            }

                            ForEach(Array((drafts[segmentType] ?? []).enumerated()), id: \.offset) { draftIndex, draft in
                                if draft.startMs != nil || draft.endMs != nil {
                                    segmentBar(
                                        range: SegmentRange(startMs: draft.startMs, endMs: draft.endMs),
                                        segmentType: segmentType,
                                        yOffset: y,
                                        width: width,
                                        isDraft: true,
                                        draft: draft
                                    )

                                    if let startMs = draft.startMs {
                                        draftHandle(x: positionX(ms: startMs, width: width), y: y)
                                    }
                                    if let endMs = draft.endMs {
                                        draftHandle(x: positionX(ms: endMs, width: width), y: y)
                                    }
                                }
                            }
                        }

                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: totalHeight)
                            .offset(x: positionX(ms: currentTimeMs, width: width))

                        if let sel = dragSelection,
                           let rowIndex = Self.segmentRowIndex[sel.segmentType] {
                            let y = densityTracksHeight + CGFloat(rowIndex) * rowHeight
                            let x0 = positionX(ms: sel.startMs, width: width)
                            let x1 = positionX(ms: sel.endMs, width: width)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(sel.segmentType.color.opacity(0.35))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(sel.segmentType.color.opacity(0.9),
                                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                                }
                                .frame(width: max(2, x1 - x0), height: rowHeight - 8)
                                .offset(x: x0, y: y + 4)
                        }

                        if let move = segmentMoveDragState,
                           let rowIndex = Self.segmentRowIndex[move.targetSegmentType] {
                            let y = densityTracksHeight + CGFloat(rowIndex) * rowHeight
                            let x0 = positionX(ms: move.currentStartMs, width: width)
                            let x1 = positionX(ms: move.currentEndMs, width: width)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(move.targetSegmentType.color.opacity(0.32))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(move.targetSegmentType.color.opacity(0.95),
                                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                }
                                .frame(width: max(2, x1 - x0), height: rowHeight - 8)
                                .offset(x: x0, y: y + 4)
                        }

                        rowSeparators(width: width)
                    }
                    .frame(width: width, height: totalHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    }
                    .background(ScrollViewFinder(controller: scrollController).frame(width: 0, height: 0))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let isShiftDrag = NSEvent.modifierFlags.contains(.shift)

                                if isShiftDrag, segmentMoveDragState == nil,
                                   handleDragState == nil, dragSelection == nil {
                                    if let hit = hitTestDraftBar(at: value.startLocation, width: width) {
                                        segmentMoveDragState = SegmentMoveDragState(
                                            sourceSegmentType: hit.segmentType,
                                            sourceDraftIndex: hit.draftIndex,
                                            sourceStartMs: hit.startMs,
                                            sourceEndMs: hit.endMs,
                                            anchorStartX: positionX(ms: hit.startMs, width: width),
                                            anchorEndX: positionX(ms: hit.endMs, width: width),
                                            currentStartMs: hit.startMs,
                                            currentEndMs: hit.endMs,
                                            targetSegmentType: hit.segmentType
                                        )
                                    }
                                }

                                if !isShiftDrag, handleDragState == nil && dragSelection == nil && segmentMoveDragState == nil {
                                    if let hit = hitTestHandle(at: value.startLocation, width: width) {
                                        handleDragState = hit
                                        onDraftHandleDragBegan()
                                    }
                                }

                                if var moveState = segmentMoveDragState {
                                    let currentStartX = moveState.anchorStartX + value.translation.width
                                    let currentEndX = moveState.anchorEndX + value.translation.width
                                    let startMs = timeForPosition(x: currentStartX, width: width)
                                    let endMs = timeForPosition(x: currentEndX, width: width)
                                    moveState.currentStartMs = min(startMs, endMs)
                                    moveState.currentEndMs = max(startMs, endMs)
                                    moveState.targetSegmentType = segmentType(atY: value.location.y)
                                    segmentMoveDragState = moveState
                                    onSeek(moveState.currentStartMs)
                                } else if let state = handleDragState {
                                    let currentX = state.initialX + value.translation.width
                                    let ms = timeForPosition(x: currentX, width: width)
                                    switch state.edge {
                                    case .start: onDraftStartDrag(state.segmentType, state.draftIndex, ms)
                                    case .end:   onDraftEndDrag(state.segmentType, state.draftIndex, ms)
                                    }
                                    onSeek(ms)
                                } else if NSEvent.modifierFlags.contains(.option) {
                                    let anchorMs = timeForPosition(x: value.startLocation.x, width: width)
                                    let currentMs = timeForPosition(x: value.location.x, width: width)
                                    let segType = segmentType(atY: value.startLocation.y)
                                    if dragSelection == nil {
                                        dragSelection = DragSelection(segmentType: segType,
                                                                      anchorMs: anchorMs,
                                                                      currentMs: currentMs)
                                    } else {
                                        dragSelection?.currentMs = currentMs
                                    }
                                    onSeek(currentMs)
                                } else if dragSelection == nil {
                                    let ms = timeForPosition(x: value.location.x, width: width)
                                    onSeek(ms)
                                }
                            }
                            .onEnded { _ in
                                let hadHandleDrag = handleDragState != nil
                                handleDragState = nil
                                if let moveState = segmentMoveDragState {
                                    onDraftMove(
                                        moveState.sourceSegmentType,
                                        moveState.sourceDraftIndex,
                                        moveState.targetSegmentType,
                                        moveState.currentStartMs,
                                        moveState.currentEndMs
                                    )
                                    segmentMoveDragState = nil
                                }
                                if let sel = dragSelection {
                                    if sel.endMs > sel.startMs {
                                        onSegmentDragSelect(sel.segmentType, sel.startMs, sel.endMs)
                                    }
                                    dragSelection = nil
                                }
                                if hadHandleDrag {
                                    onDraftHandleDragEnded()
                                }
                            }
                    )
                }
                .onHover { hovering in
                    isPointerInsideTimeline = hovering
                }
            }
            .frame(height: totalHeight + 4)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        updateViewportWidth(totalWidth: proxy.size.width)
                        reportMinimumZoom()
                    }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        updateViewportWidth(totalWidth: newWidth)
                        reportMinimumZoom()
                    }
            }
        }
        .onAppear {
            currentMinimumZoom = minimumZoom
            installScrollMonitorIfNeeded()
        }
        .onDisappear {
            removeScrollMonitor()
        }
        .onChange(of: minimumZoom) { _, newValue in
            currentMinimumZoom = newValue
        }
        .onChange(of: videoDurationMs) { _, _ in
            reportMinimumZoom()
        }
        .onChange(of: durationMs) { _, _ in
            reportMinimumZoom()
        }
        .task(id: videoLoadID) {
            // Guaranteed single call per file load; bypasses SwiftUI onChange
            // batching that can suppress intermediate durationMs changes.
            reportMinimumZoom()
        }
    }

    private var totalHeight: CGFloat {
        densityTracksHeight + rowHeight * CGFloat(SegmentType.allCases.count)
    }

    private var densityTracks: [TimelineDensityTrack] {
        [audioTrack].filter(\.hasContent)
    }

    private var densityTracksHeight: CGFloat {
        densityRowHeight * CGFloat(densityTracks.count)
    }

    @ViewBuilder
    private var labelColumn: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.12))

            ForEach(Array(densityTracks.enumerated()), id: \.offset) { index, track in
                let y = CGFloat(index) * densityRowHeight
                Rectangle()
                    .fill(Color.black.opacity(0.05))
                    .frame(width: labelColumnWidth, height: densityRowHeight)
                    .offset(y: y)

                Text(track.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .offset(y: y + 4)
            }

            let segmentTopOffset = densityTracksHeight
            ForEach(Array(SegmentType.allCases.enumerated()), id: \.element) { index, segmentType in
                let y = segmentTopOffset + CGFloat(index) * rowHeight
                Rectangle()
                    .fill(Color.black.opacity(0.05))
                    .frame(width: labelColumnWidth, height: rowHeight)
                    .offset(y: y)

                Text(segmentType.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .offset(y: y + 4)
            }

            rowSeparators(width: labelColumnWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }

    private var clampedZoomBinding: Binding<Double> {
        Binding(
            get: { max(zoom.wrappedValue, minimumZoom) },
            set: { newValue in
                zoom.wrappedValue = min(max(newValue, minimumZoom), 8)
            }
        )
    }

    private func timelineWidth(durationMs: Int, zoom: Double) -> CGFloat {
        let base = CGFloat(max(durationMs, 60_000)) / 1000.0 * 8.0
        let calculated = min(max(240, base * zoom), 48_000)
        return max(calculated, viewportWidth)
    }

    private func updateViewportWidth(totalWidth: CGFloat) {
        // Fit zoom should use the actual scrollable timeline width, not the fixed label column.
        viewportWidth = max(160, totalWidth - labelColumnWidth)
    }

    private func reportMinimumZoom() {
        guard durationMs > 0 else { return }
        let base = CGFloat(durationMs) / 1000.0 * 8.0
        guard base > 0 else { return }

        let fit = Double(viewportWidth / base)
        let clamped = min(max(fit, 0.05), 1.0)
        onMinimumZoomComputed(clamped)
    }

    private func positionX(ms: Int, width: CGFloat) -> CGFloat {
        guard durationMs > 0 else { return 0 }
        let ratio = CGFloat(max(0, min(ms, durationMs))) / CGFloat(durationMs)
        return ratio * width
    }

    private func segmentType(atY y: CGFloat) -> SegmentType {
        let offsetY = y - densityTracksHeight
        let index = max(0, min(Int(offsetY / rowHeight), SegmentType.allCases.count - 1))
        return SegmentType.allCases[index]
    }

    private func timeForPosition(x: CGFloat, width: CGFloat) -> Int {
        guard durationMs > 0 else { return 0 }
        let clamped = min(max(x, 0), width)
        let ratio = clamped / width
        return Int((ratio * CGFloat(durationMs)).rounded())
    }

    private func segmentBar(
        range: SegmentRange,
        segmentType: SegmentType,
        yOffset: CGFloat,
        width: CGFloat,
        isDraft: Bool,
        draft: SegmentDraft? = nil
    ) -> some View {
        Group {
            if let bar = barGeometry(for: range, width: width) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(segmentType.color.opacity(isDraft ? (draftOutlineOnly ? 0.0 : 0.85) : 0.45))
                    .overlay {
                        if isDraft {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    segmentType.color.opacity(0.95),
                                    style: StrokeStyle(lineWidth: draftOutlineOnly ? 2 : 1, dash: draftOutlineOnly ? [] : [5, 3])
                                )
                        }

                        if isDraft,
                           !draftOutlineOnly,
                           segmentType == .recap,
                           let draft,
                           isAutoRecapDraft(draft) {
                            GeometryReader { proxy in
                                let h = proxy.size.height
                                let w = proxy.size.width
                                let spacing: CGFloat = 6

                                Path { path in
                                    var x: CGFloat = -h
                                    while x < w {
                                        path.move(to: CGPoint(x: x, y: h))
                                        path.addLine(to: CGPoint(x: x + h, y: 0))
                                        x += spacing
                                    }
                                }
                                .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .frame(width: bar.width, height: rowHeight - 8)
                    .offset(x: bar.x, y: yOffset + 4)
            }
        }
    }

    private func isAutoRecapDraft(_ draft: SegmentDraft) -> Bool {
        guard let start = draft.startMs, let end = draft.endMs else { return false }
        return autoRecapDraftKeys.contains("\(start)-\(end)")
    }

    @ViewBuilder
    private func densityRow(track: TimelineDensityTrack, yOffset: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.05))
            .frame(width: width, height: densityRowHeight)
            .offset(y: yOffset)

        Canvas { context, size in
            guard !track.buckets.isEmpty else { return }

            let targetColumns = max(Int(size.width.rounded(.down)), 1)
            let buckets = decimateBuckets(track.buckets, targetCount: targetColumns)
            let musicBuckets = decimateBuckets(track.musicLikelihoodBuckets ?? [], targetCount: targetColumns)
            guard !buckets.isEmpty else { return }

            let bucketWidth = size.width / CGFloat(buckets.count)
            let tint: Color = track.label == "Audio" ? .mint : .orange
            let usableHeight = max(1, size.height - 3)

            for (index, rawValue) in buckets.enumerated() {
                let value = min(max(rawValue, 0), 1)
                guard value > 0 else { continue }

                let barHeight = max(1, value * usableHeight)
                let x = CGFloat(index) * bucketWidth
                let y = size.height - barHeight
                let rect = CGRect(x: x, y: y, width: max(1, bucketWidth), height: barHeight)
                let likelihood = index < musicBuckets.count ? musicBuckets[index] : 0
                let color = track.label == "Audio"
                    ? audioTint(for: likelihood)
                    : tint
                context.fill(Path(rect), with: .color(color.opacity(0.58)))
            }
        }
        .frame(width: width, height: densityRowHeight)
        .offset(y: yOffset)
    }

    private func audioTint(for musicLikelihood: Double) -> Color {
        let clamped = min(max(musicLikelihood, 0), 1)
        let lowThreshold = 0.15
        let fullBlendAt = 0.75
        let normalized = min(max((clamped - lowThreshold) / (fullBlendAt - lowThreshold), 0), 1)
        // Slight easing keeps the lower range calmer and avoids early orange flicker.
        let t = normalized * normalized

        guard
            let mint = NSColor.systemMint.usingColorSpace(.deviceRGB),
            let orange = NSColor.systemOrange.usingColorSpace(.deviceRGB)
        else {
            return .mint
        }

        let r = mint.redComponent + (orange.redComponent - mint.redComponent) * t
        let g = mint.greenComponent + (orange.greenComponent - mint.greenComponent) * t
        let b = mint.blueComponent + (orange.blueComponent - mint.blueComponent) * t

        return Color(nsColor: NSColor(calibratedRed: r, green: g, blue: b, alpha: 1))
    }

    @ViewBuilder
    private func rowSeparators(width: CGFloat) -> some View {
        let totalRows = densityTracks.count + SegmentType.allCases.count
        ForEach(1..<totalRows, id: \.self) { boundary in
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: width, height: 0.5)
                .offset(y: boundaryYOffset(for: boundary))
        }
    }

    private func boundaryYOffset(for boundary: Int) -> CGFloat {
        if boundary <= densityTracks.count {
            return CGFloat(boundary) * densityRowHeight
        }
        let segmentBoundary = boundary - densityTracks.count
        return densityTracksHeight + CGFloat(segmentBoundary) * rowHeight
    }

    private func decimateBuckets(_ buckets: [Double], targetCount: Int) -> [Double] {
        guard !buckets.isEmpty else { return [] }

        let clampedTarget = max(1, targetCount)
        guard buckets.count > clampedTarget else { return buckets }

        var result: [Double] = []
        result.reserveCapacity(clampedTarget)
        let scale = Double(buckets.count) / Double(clampedTarget)

        for index in 0..<clampedTarget {
            let start = Int(Double(index) * scale)
            let end = min(buckets.count, Int(Double(index + 1) * scale))

            if start >= end {
                let fallbackIndex = min(max(start, 0), buckets.count - 1)
                result.append(min(max(buckets[fallbackIndex], 0), 1))
                continue
            }

            var peak = 0.0
            for sourceIndex in start..<end {
                let value = buckets[sourceIndex]
                if value > peak {
                    peak = value
                }
            }
            result.append(min(max(peak, 0), 1))
        }

        return result
    }

    @ViewBuilder
    private func draftHandle(x: CGFloat, y: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: handleGrabWidth, height: rowHeight)
            .offset(x: x - handleGrabWidth / 2, y: y)
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    private func hitTestHandle(at point: CGPoint, width: CGFloat) -> HandleDragState? {
        for (rowIndex, segType) in SegmentType.allCases.enumerated() {
            let rowY = densityTracksHeight + CGFloat(rowIndex) * rowHeight
            let inRowY = point.y >= rowY && point.y <= (rowY + rowHeight)
            guard inRowY else { continue }

            for (index, draft) in (drafts[segType] ?? []).enumerated() {
                guard draft.startMs != nil || draft.endMs != nil else { continue }

                if let startMs = draft.startMs {
                    let hx = positionX(ms: startMs, width: width)
                    if abs(point.x - hx) <= handleGrabWidth / 2 {
                        return HandleDragState(segmentType: segType, draftIndex: index, edge: .start, initialX: point.x)
                    }
                }

                if let endMs = draft.endMs {
                    let hx = positionX(ms: endMs, width: width)
                    if abs(point.x - hx) <= handleGrabWidth / 2 {
                        return HandleDragState(segmentType: segType, draftIndex: index, edge: .end, initialX: point.x)
                    }
                }
            }
        }
        return nil
    }

    private func hitTestDraftBar(at point: CGPoint, width: CGFloat) -> (segmentType: SegmentType, draftIndex: Int, startMs: Int, endMs: Int)? {
        for (rowIndex, segType) in SegmentType.allCases.enumerated() {
            let rowY = densityTracksHeight + CGFloat(rowIndex) * rowHeight
            let inRowY = point.y >= rowY && point.y <= (rowY + rowHeight)
            guard inRowY else { continue }

            for (index, draft) in (drafts[segType] ?? []).enumerated() {
                guard let startMs = draft.startMs, let endMs = draft.endMs else { continue }
                guard let bar = barGeometry(for: SegmentRange(startMs: startMs, endMs: endMs), width: width) else { continue }
                let barRect = CGRect(x: bar.x, y: rowY + 4, width: bar.width, height: rowHeight - 8)
                if barRect.contains(point) {
                    return (segType, index, startMs, endMs)
                }
            }
        }
        return nil
    }

    private func barGeometry(for range: SegmentRange, width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        let start = max(range.startMs ?? 0, 0)
        let end = range.endMs ?? durationMs

        guard durationMs > 0 else { return nil }
        guard end >= start else { return nil }

        let x = positionX(ms: start, width: width)
        let endX = positionX(ms: end, width: width)
        let barWidth = max(2, endX - x)

        return (x: x, width: barWidth)
    }

    private func installScrollMonitorIfNeeded() {
        guard scrollMonitor == nil else { return }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isPointerInsideTimeline else { return event }
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }

            let deltaY = event.scrollingDeltaY
            let locationInWindow = event.locationInWindow
            applyScrollZoom(deltaY: deltaY, locationInWindow: locationInWindow)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func applyScrollZoom(deltaY: CGFloat, locationInWindow: CGPoint) {
        let sensitivity = 0.0035
        let factor = exp(deltaY * sensitivity)
        let oldZoom = zoom.wrappedValue
        let newZoom = min(max(oldZoom * factor, currentMinimumZoom), 8)
        guard newZoom != oldZoom else { return }

        // Calculate the new scroll offset so the point under the cursor stays fixed.
        if let mouseXInViewport = scrollController.mouseXInViewport(locationInWindow: locationInWindow) {
            let oldOffsetX = scrollController.contentOffsetX
            let mouseXInContent = oldOffsetX + mouseXInViewport
            // Content width scales proportionally with zoom.
            let newMouseXInContent = mouseXInContent * (newZoom / oldZoom)
            let newOffsetX = newMouseXInContent - mouseXInViewport
            zoom.wrappedValue = newZoom
            // Scroll after SwiftUI has laid out the wider/narrower content.
            DispatchQueue.main.async {
                scrollController.scrollToX(newOffsetX)
            }
        } else {
            zoom.wrappedValue = newZoom
        }
    }
}

private struct TimelineHelpPopover: View {
    private let draftRows: [(String, String)] = [
        ("I / ⇧I / ⌥I", "Start / End / No Intro"),
        ("R / ⇧R / ⌥R", "Start / End / No Recap"),
        ("C / ⇧C / ⌥C", "Start / End / No Credits"),
        ("P / ⇧P / ⌥P", "Start / End / No Preview")
    ]

    private let jumpRows: [(String, String)] = [
        ("⌘I / ⌘⇧I", "Next Intro Start / End"),
        ("⌘R / ⌘⇧R", "Next Recap Start / End"),
        ("⌘C / ⌘⇧C", "Next Credits Start / End"),
        ("⌘P / ⌘⇧P", "Next Preview Start / End")
    ]

    private let boundaryRows: [(String, String)] = [
        ("⇧← / ⇧→", "Jump to previous / next scene transition"),
        ("⌘← / ⌘→", "Nudge nearest boundary ±1 frame"),
        ("⌥← / ⌥→", "Nudge nearest boundary ±1 s"),
        (",", "Move nearest segment boundary to playhead")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline Help")
                .font(.headline)

            Divider()

            Text("Shortcuts")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 10) {
                TimelineShortcutGroupCard(title: "Draft", rows: draftRows)
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 240)
                TimelineShortcutGroupCard(title: "Jump", rows: jumpRows)
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
                TimelineShortcutGroupCard(title: "Boundary", rows: boundaryRows)
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
            }

            Divider()

            Text("Interactions")
                .font(.subheadline.weight(.semibold))
            Label("⌘⇧N: open next video file", systemImage: "arrow.right.circle")
            Label("Drag on timeline: seek playhead", systemImage: "arrow.left.and.line.vertical.and.arrow.right")
            Label("Click thumbnail in frame strip: seek and enter single-frame mode", systemImage: "photo.on.rectangle")
            Label("⌥ + Drag: create segment in hovered row", systemImage: "arrow.up.left.and.arrow.down.right")
            Label("⇧ + Drag on draft bar: move full segment and change row/type", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            Label("Drag segment edges: adjust start and end", systemImage: "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right.fill")
            Label("Set icon beside time fields: copy playhead into start/end", systemImage: "arrow.down.to.line.compact")
            Label("Scope icon in draft row: jump playhead to boundary", systemImage: "scope")
            Label("Vertical trackpad scroll: zoom timeline", systemImage: "arrow.up.and.down")
        }
        .font(.caption)
        .frame(width: 700, alignment: .leading)
    }
}

private struct TimelineShortcutGroupCard: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                timelineShortcutLine(row.0, row.1)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.18))
        )
    }
}

private struct TimelineShortcutLine: View {
    let key: String
    let action: String

    private var keyParts: [String] {
        key
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(keyParts.enumerated()), id: \.offset) { index, part in
                    Text(part)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.black.opacity(0.12))
                        )

                    if index < keyParts.count - 1 {
                        Text("/")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 110, alignment: .leading)

            Text(action)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func timelineShortcutLine(_ key: String, _ action: String) -> some View {
    TimelineShortcutLine(key: key, action: action)
}
