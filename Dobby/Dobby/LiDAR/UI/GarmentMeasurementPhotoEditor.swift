import SwiftUI
import UIKit

/// The photograph and every overlay share the captured preview's display crop.
/// Storage and depth sampling retain the original, unrotated sensor coordinates.
struct GarmentMeasurementPhotoEditor: View {
    let image: UIImage?
    let snapshot: CaptureSnapshot
    let editableLandmarks: GarmentLandmarkSet
    let definitions: [MeasurementDefinition]
    let values: [MeasurementValue]
    let showLabels: Bool
    let isEnabled: Bool
    let isRecalculating: Bool
    var showsEnlargeControl = true
    var usesResultPointStyleForEndpoints: Bool = false
    var allowsViewportZoom = false
    var pendingPointIDs: Set<String> = []
    /// Display-only space covered by the result sheet at the bottom of the photo.
    var magnifierBottomInset: CGFloat = 0
    let onEnlarge: () -> Void
    let onMove: (String, ImagePoint) -> Void
    let onEditingChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 21
    @ScaledMetric(relativeTo: .caption2) private var labelFontSize: CGFloat = 11
    @State private var selectedPointID: String?
    @State private var drag: PointDrag?
    @State private var lockedMagnifierRect: CGRect?
    @State private var dragEpoch = UUID()
    @GestureState private var gestureIsActive = false
    @State private var viewport = MeasurementPhotoViewport()
    @State private var interactionID = UUID()
    @State private var nativePointDragIsActive = false

    private var pointDragIsActive: Bool { allowsViewportZoom ? nativePointDragIsActive : gestureIsActive }
    @State private var displayedPointCenters: [String: CGPoint] = [:]
    @State private var windowCenterInPhoto: CGPoint?

    private struct PointDrag {
        let sessionID = UUID()
        let id: String
        let start: ImagePoint
        let annotations: [Annotation]
        let frameID: UUID
        let orientation: ImageOrientation
        let displayCrop: PhotoDisplayCrop
        let photoSize: CGSize
        let viewport: MeasurementPhotoViewport
        var current: ImagePoint
    }

    private var handles: [GarmentLandmark] {
        editableLandmarks.points.filter { $0.isVisible && $0.point.isValid }
    }

    private var selectedPoint: GarmentLandmark? {
        handles.first { $0.id == selectedPointID }
    }

    private var displayCrop: PhotoDisplayCrop {
        guard let crop = snapshot.presentationCrop, crop.isValid else { return .full }
        return crop
    }

    private func magnifiedPoint(in size: CGSize) -> GarmentLandmark? {
        guard image != nil, isEnabled, scenePhase == .active, pointDragIsActive, let drag,
              drag.frameID == snapshot.frame.frameID,
              drag.orientation == snapshot.frame.orientation,
              drag.displayCrop == displayCrop,
              drag.photoSize == size, drag.viewport == viewport else { return nil }
        return handles.first { $0.id == drag.id }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let annotations = annotations(in: size).map(displayedAnnotation)
            ZStack(alignment: .topLeading) {
                photograph(size: size)
                measurementLines(annotations)
                ZStack(alignment: .topLeading) {
                    if showLabels {
                        ForEach(annotations) { item in
                            if let center = item.labelCenter {
                                measurementLabel(item).position(center)
                            }
                        }
                    }
                }.frame(width: size.width, height: size.height)
                if usesResultPointStyleForEndpoints {
                    ForEach(Array(uniqueEndpoints(in: annotations).enumerated()), id: \.offset) { _, endpoint in
                        MeasurementPointMarker()
                            .scaleEffect(viewport.scale)
                            .position(endpoint)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                // The small markers sit above labels. Their larger invisible
                // touch regions take priority when a finger grabs nearby.
                ForEach(handles) { point in
                    pointHandle(point, size: size)
                        .position(viewport.screenPoint(for: screenPoint(previewPoint(point), size: size)))
                }
                if allowsViewportZoom {
                    MeasurementPhotoViewportInteraction(viewport: viewport,
                        pointTargets: handles.map {
                            MeasurementPhotoPointTarget(id: $0.id,
                                center: viewport.screenPoint(for: screenPoint(previewPoint($0), size: size)))
                        }, excludedRects: interactionExcludedRects(in: size),
                        interactionID: interactionID,
                        isEnabled: isEnabled && image != nil && scenePhase == .active,
                        onViewportGestureBegan: { cancelDrag(invalidateInteraction: false) },
                        onViewportChange: { setViewport($0) },
                        onPointDragBegan: { beginNativeDrag($0, size: size) },
                        onPointDragChanged: { updateNativeDrag($0, translation: $1, size: size) },
                        onPointDragEnded: { endNativeDrag($0, size: size) },
                        onPointDragCancelled: cancelNativeDrag)
                        .accessibilityHidden(true)
                }
                if let image, let point = magnifiedPoint(in: size) {
                    let loupe = magnifierRect(in: size)
                    magnifier(image: image, point: point, photoSize: size)
                        .position(x: loupe.midX, y: loupe.midY).allowsHitTesting(false)
                        .transition(.identity)
                }
                if showsZoomControl {
                    Button {
                        if allowsViewportZoom { toggleZoom(in: size) }
                        else { onEnlarge() }
                    } label: {
                        Group {
                            if allowsViewportZoom && viewport.isZoomed {
                                Text("1×").font(.system(size: 14, weight: .semibold))
                            } else {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                            .frame(width: 36, height: 36)
                            .modifier(MeasurementGlassCapsule(reduceTransparency: reduceTransparency))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.white)
                        .disabled(image == nil || !isEnabled)
                        .position(x: size.width - 30, y: 30)
                        .accessibilityLabel(allowsViewportZoom && viewport.isZoomed ? "사진을 원래 크기로 보기" : "촬영 사진 확대")
                        .accessibilityValue(allowsViewportZoom ? String(format: "%.1f배", viewport.scale) : "")
                        .accessibilityIdentifier("enlargeGarmentPhoto")
                }
            }.frame(width: size.width, height: size.height).clipped()
                .coordinateSpace(name: "garmentPhoto")
                .background {
                    MeasurementPhotoWindowCenterReader { windowCenterInPhoto = $0 }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onPreferenceChange(MeasurementPointScreenCentersKey.self) { centers in
                    displayedPointCenters = centers
                }
                .onChange(of: size) { _, _ in
                    // A rotation/window resize invalidates the cached display
                    // geometry, so finish without committing that touch preview.
                    cancelDrag()
                    setViewport(.init())
                }
        }
        .aspectRatio(SnapshotPresentation.aspectRatio(for: snapshot) * CGFloat(displayCrop.width / displayCrop.height),
            contentMode: .fit)
        .accessibilityElement(children: .contain)
        .onChange(of: gestureIsActive) { _, active in
            // Interrupted touches (for example, app backgrounding) don't always
            // call onEnded. Discard that preview and unblock confirmation.
            guard !allowsViewportZoom, !active, let sessionID = drag?.sessionID else { return }
            // Hide via gestureIsActive immediately, but let a normal onEnded
            // commit before cancelling an interrupted stream. An old cleanup
            // cannot erase a new drag that started in the meantime.
            Task { @MainActor in
                guard !gestureIsActive, drag?.sessionID == sessionID else { return }
                cancelDrag()
            }
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancelDrag() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancelDrag() } }
        .onChange(of: snapshot.frame.frameID) { _, _ in resetViewport() }
        .onChange(of: snapshot.frame.orientation) { _, _ in resetViewport() }
        .onChange(of: displayCrop) { _, _ in resetViewport() }
        .onChange(of: handles.map(\.id)) { _, _ in cancelDrag() }
        .onChange(of: definitions.map(\.id)) { _, _ in cancelDrag() }
        .onChange(of: image == nil) { _, missing in if missing { cancelDrag() } }
        .sensoryFeedback(.selection, trigger: drag?.sessionID) { _, session in session != nil }
        .onDisappear { cancelDrag() }
    }

    private func cancelDrag(invalidateInteraction: Bool = true) {
        // Replacing the gesture subtree invalidates callbacks captured before
        // a rotation, scene change or other cancellation, including late ends.
        let wasEditing = drag != nil || nativePointDragIsActive
        guard invalidateInteraction || wasEditing else { return }
        dragEpoch = UUID()
        if invalidateInteraction { interactionID = UUID() }
        drag = nil
        lockedMagnifierRect = nil
        nativePointDragIsActive = false
        if wasEditing { onEditingChanged(false) }
    }

    private func cancelNativeDrag() {
        // UIKit can cancel while its representable updates or lays out. Defer
        // SwiftUI state cleanup, but never clear a newer finger's edit.
        guard let token = drag?.sessionID else { return }
        Task { @MainActor in
            guard drag?.sessionID == token else { return }
            cancelDrag(invalidateInteraction: false)
        }
    }

    private var showsZoomControl: Bool {
        showsEnlargeControl && !(allowsViewportZoom && viewport.isZoomed)
    }

    private func zoomControlRect(in size: CGSize) -> CGRect {
        CGRect(x: size.width - 52, y: 8, width: 44, height: 44)
    }

    private func interactionExcludedRects(in size: CGSize) -> [CGRect] {
        var rects = showsZoomControl ? [zoomControlRect(in: size)] : []
        // The recognizer is attached to the hosting controller, so a SwiftUI
        // overlay alone cannot reliably stop it from beginning under the sheet.
        if magnifierBottomInset.isFinite, magnifierBottomInset > 0 {
            let height = min(size.height, magnifierBottomInset)
            rects.append(CGRect(x: 0, y: size.height - height, width: size.width, height: height))
        }
        return rects
    }

    private func setViewport(_ value: MeasurementPhotoViewport) {
        // Canvas pixels and overlay positions must adopt the same transform
        // in one frame; independent implicit animations would separate them.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { viewport = value }
    }

    private func resetViewport() {
        cancelDrag()
        setViewport(.init())
    }

    private func toggleZoom(in size: CGSize) {
        guard allowsViewportZoom, isEnabled, image != nil else { return }
        cancelDrag()
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        setViewport(viewport.isZoomed ? .init()
            : viewport.applyingPinch(magnification: 2, from: center, to: center, in: size))
    }

    private func beginNativeDrag(_ id: String, size: CGSize) {
        guard isEnabled, scenePhase == .active, image != nil,
              let point = handles.first(where: { $0.id == id }) else { return }
        selectedPointID = id
        lockedMagnifierRect = MeasurementMagnifierPlacement.rect(photoSize: size,
            point: displayedPointCenters[id] ?? viewport.screenPoint(for: screenPoint(point.point, size: size)),
            windowCenter: windowCenterInPhoto ?? CGPoint(x: size.width / 2, y: size.height / 2))
        drag = .init(id: id, start: point.point, annotations: annotations(in: size),
            frameID: snapshot.frame.frameID, orientation: snapshot.frame.orientation,
            displayCrop: displayCrop, photoSize: size, viewport: viewport, current: point.point)
        nativePointDragIsActive = true
        UISelectionFeedbackGenerator().selectionChanged()
        onEditingChanged(true)
    }

    private func updateNativeDrag(_ id: String, translation: CGSize, size: CGSize) {
        guard isEnabled, scenePhase == .active, let moving = drag,
              moving.id == id, moving.frameID == snapshot.frame.frameID,
              moving.orientation == snapshot.frame.orientation, moving.displayCrop == displayCrop,
              moving.photoSize == size, moving.viewport == viewport else {
            cancelDrag(invalidateInteraction: false)
            return
        }
        // Start at the marker, not the initial touch in its larger hit region.
        // Invert the display zoom once, then reuse the crop/orientation mapping
        // into original RGB coordinates used by the depth measurement pipeline.
        let start = moving.viewport.screenPoint(for: screenPoint(moving.start, size: size))
        let location = CGPoint(x: min(size.width, max(0, start.x + translation.width)),
            y: min(size.height, max(0, start.y + translation.height)))
        if let original = GarmentPhotoGeometry.originalPoint(at: moving.viewport.photoPoint(for: location),
            photoSize: size, orientation: snapshot.frame.orientation, displayCrop: displayCrop) {
            drag?.current = original
        }
    }

    private func endNativeDrag(_ id: String, size: CGSize) {
        guard isEnabled, scenePhase == .active, let completed = drag,
              completed.id == id, completed.frameID == snapshot.frame.frameID,
              completed.orientation == snapshot.frame.orientation, completed.displayCrop == displayCrop,
              completed.photoSize == size, completed.viewport == viewport,
              handles.contains(where: { $0.id == id }) else {
            cancelDrag(invalidateInteraction: false)
            return
        }
        drag = nil
        lockedMagnifierRect = nil
        nativePointDragIsActive = false
        // An unchanged endpoint must not become a manual correction or trigger
        // recalculation merely because a finger touched its neighbourhood.
        if abs(completed.current.x - completed.start.x) + abs(completed.current.y - completed.start.y) > 1e-10 {
            onMove(id, completed.current)
        }
        onEditingChanged(false)
    }

    private func photograph(size: CGSize) -> some View {
        Group {
            if let image {
                Canvas { context, _ in
                    context.draw(context.resolve(Image(uiImage: image)),
                        in: viewport.screenRect(for: GarmentPhotoGeometry.photoRect(photoSize: size, displayCrop: displayCrop)))
                }.frame(width: size.width, height: size.height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel("촬영한 옷과 측정점")
                    .accessibilityIdentifier("garmentMeasurementPhoto")
                    .accessibilityValue(!isEnabled ? "처리 중, 사진 조절 불가"
                        : allowsViewportZoom ? String(format: "사진 확대 %.1f배", viewport.scale) : "")
                    .accessibilityHint(allowsViewportZoom
                        ? "위아래로 쓸어 사진 배율을 조절하고, 세 손가락으로 쓸어 확대된 사진을 이동할 수 있어요. 측정점은 각각 선택해 조절해 주세요."
                        : "각 측정점을 선택하면 방향별로 위치를 조절할 수 있어요")
                    .modifier(MeasurementPhotoAccessibilityActions(isEnabled: allowsViewportZoom && isEnabled,
                        onAdjust: { direction in
                            switch direction {
                            case .increment: adjustAccessibleZoom(by: 0.5, size: size)
                            case .decrement: adjustAccessibleZoom(by: -0.5, size: size)
                            @unknown default: break
                            }
                        }, onReset: {
                            guard isEnabled, scenePhase == .active else { return }
                            resetViewport()
                            VoiceOverAnnouncement.post("사진을 원래 크기로 되돌렸어요")
                        }, onScroll: { scrollAccessiblePhoto($0, size: size) }))
            } else {
                ContentUnavailableView("사진을 불러올 수 없어요", systemImage: "photo")
                    .frame(width: size.width, height: size.height)
                    .accessibilityIdentifier("garmentMeasurementPhoto")
            }
        }
    }

    private func measurementLines(_ annotations: [Annotation]) -> some View {
        Canvas { context, size in
            for item in annotations {
                var path = Path()
                path.move(to: item.start)
                path.addLine(to: item.end)
                // Photo annotations grow as one image: stroke thickness and
                // dash spacing use the same display scale as their endpoints.
                let scale = viewport.scale
                context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 3 * scale)
                context.stroke(path, with: .color(.white.opacity(0.95)),
                    style: .init(lineWidth: 1.5 * scale, lineCap: .round, dash: [4 * scale, 5 * scale]))
                // Endpoint indicators accompany the measurement line; editable
                // physical and contour handles are drawn separately above it.
                if !usesResultPointStyleForEndpoints {
                    for endpoint in [item.start, item.end] {
                        let marker = Path(ellipseIn: CGRect(x: endpoint.x - 3 * scale, y: endpoint.y - 3 * scale,
                            width: 6 * scale, height: 6 * scale))
                        context.fill(marker, with: .color(.white))
                    }
                }
                let middle = CGPoint(x: (item.start.x + item.end.x) / 2, y: (item.start.y + item.end.y) / 2)
                if showLabels, item.isCallout, let center = item.labelCenter {
                    let labelRect = CGRect(x: center.x - item.labelSize.width * scale / 2,
                        y: center.y - item.labelSize.height * scale / 2,
                        width: item.labelSize.width * scale, height: item.labelSize.height * scale)
                    let edge = CGPoint(x: min(labelRect.maxX, max(labelRect.minX, middle.x)),
                        y: min(labelRect.maxY, max(labelRect.minY, middle.y)))
                    var leader = Path()
                    leader.move(to: middle)
                    leader.addLine(to: edge)
                    context.stroke(leader, with: .color(.black.opacity(0.45)), lineWidth: 2 * scale)
                    context.stroke(leader, with: .color(.white.opacity(0.55)), lineWidth: 0.75 * scale)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func uniqueEndpoints(in annotations: [Annotation]) -> [CGPoint] {
        annotations.flatMap { [$0.start, $0.end] }.reduce(into: []) { endpoints, endpoint in
            if !endpoints.contains(endpoint) { endpoints.append(endpoint) }
        }
    }

    private func measurementLabel(_ item: Annotation) -> some View {
        // Render at the enlarged font size instead of magnifying a small text
        // bitmap. Geometry still uses the same uniform photo scale.
        let scale = viewport.scale
        return HStack(spacing: 4 * scale) {
            Text(GarmentMeasurementText.shortTitle(item.definition))
                .font(.custom("Pretendard-Regular", size: labelFontSize * scale))
                .tracking(0.06 * scale)
                .fixedSize(horizontal: true, vertical: false)
            Text(drag != nil || isRecalculating ? "…" : visibleMeasurementValue(item.value))
                .font(.custom("Pretendard-SemiBold", size: labelFontSize * scale))
                .tracking(0.06 * scale)
                .fixedSize(horizontal: true, vertical: false)
        }.foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 4 * scale, y: 4 * scale)
            .lineLimit(1).padding(.horizontal, 4 * scale)
            .frame(width: item.labelSize.width * scale, height: item.labelSize.height * scale)
            .fixedSize(horizontal: true, vertical: true)
            .modifier(MeasurementValueCapsule(reduceTransparency: reduceTransparency))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.definition.title), \(drag != nil || isRecalculating ? "재계산 중" : GarmentMeasurementText.value(item.value))")
            .accessibilityIdentifier("garmentMeasurementLabel_\(item.id)")
    }

    private func pointHandle(_ point: GarmentLandmark, size: CGSize) -> some View {
        let epoch = dragEpoch
        let pending = pendingPointIDs.contains(point.id)
        let center = viewport.screenPoint(for: screenPoint(previewPoint(point), size: size))
        let neighbors = handles.filter { $0.id != point.id }.map {
            let other = viewport.screenPoint(for: screenPoint(previewPoint($0), size: size))
            return CGPoint(x: other.x - center.x, y: other.y - center.y)
        }
        let button = Button {
            selectedPointID = point.id
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            MeasurementPointMarker(isPending: pending)
                // Enlarge the visible dot, preserving the surrounding 56pt hit
                // target so adjacent points and empty-space pans stay usable.
                .scaleEffect(viewport.scale)
                .frame(width: MeasurementPointMarkerStyle.touchTargetDiameter,
                    height: MeasurementPointMarkerStyle.touchTargetDiameter)
                .contentShape(MeasurementPointHitShape(neighborOffsets: neighbors))
        }.buttonStyle(.plain).disabled(!isEnabled)
        let movement = DragGesture(minimumDistance: 2, coordinateSpace: .named("garmentPhoto"))
                .updating($gestureIsActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard epoch == dragEpoch, isEnabled, scenePhase == .active else { return }
                    if let drag, drag.id != point.id { return }
                    if drag == nil {
                        selectedPointID = point.id
                        lockedMagnifierRect = MeasurementMagnifierPlacement.rect(photoSize: size,
                            point: displayedPointCenters[point.id] ?? screenPoint(point.point, size: size),
                            windowCenter: windowCenterInPhoto ?? CGPoint(x: size.width / 2, y: size.height / 2))
                        drag = .init(id: point.id, start: point.point,
                            annotations: annotations(in: size), frameID: snapshot.frame.frameID,
                            orientation: snapshot.frame.orientation, displayCrop: displayCrop,
                            photoSize: size, viewport: viewport, current: point.point)
                        UISelectionFeedbackGenerator().selectionChanged()
                        onEditingChanged(true)
                    }
                    guard let currentDrag = drag else { return }
                    guard currentDrag.frameID == snapshot.frame.frameID,
                          currentDrag.orientation == snapshot.frame.orientation,
                          currentDrag.displayCrop == displayCrop,
                          currentDrag.photoSize == size else { cancelDrag(); return }
                    // Use translation from the original point rather than the
                    // finger's initial hit position, so grabbing its ring never jumps.
                    let start = screenPoint(currentDrag.start, size: size)
                    let location = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                    if let original = GarmentPhotoGeometry.originalPoint(at: location, photoSize: size,
                        orientation: snapshot.frame.orientation, displayCrop: displayCrop) {
                        drag?.current = original
                    }
                }.onEnded { _ in
                    guard epoch == dragEpoch else { return }
                    guard let completed = drag, completed.id == point.id else { return }
                    guard isEnabled, scenePhase == .active,
                          completed.frameID == snapshot.frame.frameID,
                          completed.orientation == snapshot.frame.orientation,
                          completed.displayCrop == displayCrop,
                          completed.photoSize == size,
                          handles.contains(where: { $0.id == completed.id }) else { cancelDrag(); return }
                    drag = nil
                    lockedMagnifierRect = nil
                    dragEpoch = UUID()
                    onMove(completed.id, completed.current)
                    onEditingChanged(false)
                }
        return Group {
            if allowsViewportZoom { button }
            else { button.highPriorityGesture(movement) }
        }
            .id(epoch)
            .background {
                GeometryReader { handleGeometry in
                    let frame = handleGeometry.frame(in: .named("garmentPhoto"))
                    Color.clear.preference(key: MeasurementPointScreenCentersKey.self,
                        value: [point.id: CGPoint(x: frame.midX, y: frame.midY)])
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .accessibilityLabel(GarmentPointName.title(point.id))
            .accessibilityValue(accessiblePointValue(point, pending: pending))
            .accessibilityCustomContent(Text("관련 실측값"), Text(accessiblePointMeasurements(point)), importance: .high)
            .accessibilityHint(MeasurementPointAccessibilityText.movementHint)
            .accessibilityAddTraits(selectedPointID == point.id ? .isSelected : [])
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(point, dx: 2, dy: 0, size: size)
                case .decrement: nudge(point, dx: -2, dy: 0, size: size)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "왼쪽으로 이동") { nudge(point, dx: -2, dy: 0, size: size) }
            .accessibilityAction(named: "오른쪽으로 이동") { nudge(point, dx: 2, dy: 0, size: size) }
            .accessibilityAction(named: "위로 이동") { nudge(point, dx: 0, dy: -2, size: size) }
            .accessibilityAction(named: "아래로 이동") { nudge(point, dx: 0, dy: 2, size: size) }
            .accessibilityIdentifier("garmentMeasurementPoint_\(point.id)")
    }

    private func nudge(_ point: GarmentLandmark, dx: CGFloat, dy: CGFloat, size: CGSize) {
        guard isEnabled, image != nil, scenePhase == .active, drag == nil,
              !nativePointDragIsActive, size.width > 0, size.height > 0 else { return }
        selectedPointID = point.id
        let current = viewport.screenPoint(for: screenPoint(point.point, size: size))
        let photoPoint = viewport.photoPoint(for: .init(x: current.x + dx, y: current.y + dy))
        guard let original = GarmentPhotoGeometry.originalPoint(at: photoPoint,
            photoSize: size, orientation: snapshot.frame.orientation, displayCrop: displayCrop) else {
            VoiceOverAnnouncement.post("사진 가장자리예요. 더 이동할 수 없어요")
            return
        }
        guard original != point.point else {
            VoiceOverAnnouncement.post("사진 가장자리예요. 더 이동할 수 없어요")
            return
        }
        onMove(point.id, original)
        let displayed = ImageCoordinateTransform.originalToDisplay(original, orientation: snapshot.frame.orientation)
        VoiceOverAnnouncement.post("\(GarmentPointName.title(point.id)), \(MeasurementPointAccessibilityText.direction(dx: dx, dy: dy)). \(MeasurementPointAccessibilityText.position(displayed, crop: displayCrop))")
    }

    private func accessiblePointValue(_ point: GarmentLandmark, pending: Bool) -> String {
        let display = ImageCoordinateTransform.originalToDisplay(previewPoint(point), orientation: snapshot.frame.orientation)
        return "\(pending ? "위치 확인 필요" : "위치 지정됨"). \(MeasurementPointAccessibilityText.position(display, crop: displayCrop))"
    }

    private func accessiblePointMeasurements(_ point: GarmentLandmark) -> String {
        let related = Set(definitions.filter { $0.landmarkIDs.contains(point.id) }.map(\.id))
        if isRecalculating { return "치수 다시 계산 중" }
        let measurements = values.filter { related.contains($0.id) }.map {
            "\($0.title), \(GarmentMeasurementText.value($0).replacingOccurrences(of: " cm", with: " 센티미터"))"
        }
        return measurements.isEmpty ? "전체 치수는 실측값 패널에서 확인할 수 있어요" : measurements.joined(separator: ". ")
    }

    private func adjustAccessibleZoom(by amount: CGFloat, size: CGSize) {
        guard allowsViewportZoom, isEnabled, image != nil, scenePhase == .active else { return }
        let target = min(MeasurementPhotoViewport.maximumScale, max(1, viewport.scale + amount))
        guard target != viewport.scale else { return }
        cancelDrag()
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        setViewport(viewport.applyingPinch(magnification: target / viewport.scale, from: center, to: center, in: size))
    }

    private func scrollAccessiblePhoto(_ edge: Edge, size: CGSize) {
        guard allowsViewportZoom, viewport.isZoomed, isEnabled, image != nil, scenePhase == .active else { return }
        let translation: CGSize
        let direction: String
        switch edge {
        case .top: translation = CGSize(width: 0, height: size.height * 0.35); direction = "위쪽"
        case .bottom: translation = CGSize(width: 0, height: -size.height * 0.35); direction = "아래쪽"
        case .leading: translation = CGSize(width: size.width * 0.35, height: 0); direction = "왼쪽"
        case .trailing: translation = CGSize(width: -size.width * 0.35, height: 0); direction = "오른쪽"
        @unknown default: return
        }
        cancelDrag()
        let next = viewport.applyingPan(translation, in: size)
        guard next != viewport else { VoiceOverAnnouncement.post("사진 가장자리예요"); return }
        setViewport(next)
        VoiceOverAnnouncement.post("사진의 \(direction) 영역")
    }

    private func magnifier(image: UIImage, point: GarmentLandmark, photoSize: CGSize) -> some View {
        let loupeSize = magnifierRect(in: photoSize).size
        let display = ImageCoordinateTransform.originalToDisplay(previewPoint(point), orientation: snapshot.frame.orientation)
        let layout = GarmentPhotoGeometry.magnifier(displayPoint: display, photoSize: photoSize,
            loupeSize: loupeSize, displayCrop: displayCrop, magnification: 3 * viewport.scale)
        // A bounded canvas avoids a three-times-larger SwiftUI Image's
        // layout/accessibility bounds leaking outside the clipped inset.
        return Canvas { context, size in
            // Near the photo edge, keep the actual selected pixel under the
            // fixed reticle instead of moving the reticle away from the centre.
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
            context.draw(context.resolve(Image(uiImage: image)),
                in: CGRect(origin: layout.imageOrigin, size: layout.imageSize))
            let radius: CGFloat = 9.12, lineWidth: CGFloat = 1
            // Use layout points, as with the surrounding iOS controls. The gap
            // is measured to the ring's inner stroke edge, not its centreline.
            let ringGap: CGFloat = 3.3
            let crossExtent = radius - lineWidth / 2 - ringGap
            let marker = CGRect(x: layout.crosshair.x - radius, y: layout.crosshair.y - radius,
                width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: marker), with: .color(.black.opacity(0.2)))
            context.stroke(Path(ellipseIn: marker), with: .color(.white), lineWidth: lineWidth)
            var cross = Path()
            cross.move(to: .init(x: layout.crosshair.x - crossExtent, y: layout.crosshair.y))
            cross.addLine(to: .init(x: layout.crosshair.x + crossExtent, y: layout.crosshair.y))
            cross.move(to: .init(x: layout.crosshair.x, y: layout.crosshair.y - crossExtent))
            cross.addLine(to: .init(x: layout.crosshair.x, y: layout.crosshair.y + crossExtent))
            context.stroke(cross, with: .color(.white), style: .init(lineWidth: lineWidth, lineCap: .butt))
        }.frame(width: loupeSize.width, height: loupeSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18.056))
            .overlay(RoundedRectangle(cornerRadius: 18.056).strokeBorder(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            // The image is deliberately three times larger than the viewport.
            // Expose only the bounded loupe, never the clipped image's AX frame.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(GarmentPointName.title(point.id)) 확대, 현재 사진의 3배")
            .accessibilityValue(String(format: "x %.4f, y %.4f", previewPoint(point).x, previewPoint(point).y))
            .accessibilityIdentifier("garmentPointMagnifier")
    }

    private struct Annotation: Identifiable {
        let definition: MeasurementDefinition
        let value: MeasurementValue
        let start: CGPoint
        let end: CGPoint
        let labelCenter: CGPoint?
        let labelSize: CGSize
        let isCallout: Bool
        var id: String { definition.id }
    }

    private func displayedAnnotation(_ item: Annotation) -> Annotation {
        // The capsule's dimensions scale at its transformed center, matching
        // the photo, line and point visuals without changing source coordinates.
        .init(definition: item.definition, value: item.value,
            start: viewport.screenPoint(for: item.start), end: viewport.screenPoint(for: item.end),
            labelCenter: item.labelCenter.map { viewport.screenPoint(for: $0) },
            labelSize: item.labelSize, isCallout: item.isCallout)
    }

    private func annotations(in size: CGSize) -> [Annotation] {
        if let moving = drag {
            // Cache text sizes during touch updates, but place captions against
            // the current endpoints so a shortened line cannot obscure its dots.
            let items: [Annotation] = moving.annotations.map { item in
                guard item.definition.projection == nil else { return item }
                let start = item.value.points[0].id == moving.id ? screenPoint(moving.current, size: size) : item.start
                let end = item.value.points[1].id == moving.id ? screenPoint(moving.current, size: size) : item.end
                return .init(definition: item.definition, value: item.value,
                    start: start, end: end, labelCenter: nil,
                    labelSize: item.labelSize, isCallout: item.isCallout)
            }
            return positionedAnnotations(items, in: size)
        }
        let items: [Annotation] = definitions.compactMap { definition in
            guard definition.landmarkIDs.count == 2,
                  let value = values.first(where: { $0.id == definition.id }),
                  value.hasUsableMeasurement,
                  value.points.count == 2, value.points.allSatisfy({ $0.imagePoint.isValid }) else { return nil }
            let start = screenPoint(value.points[0].imagePoint, size: size)
            let end = screenPoint(value.points[1].imagePoint, size: size)
            // Match the Figma label faces and the visible capsule's 4pt gap
            // and 4pt horizontal padding when reserving annotation space.
            let titleFont = UIFont(name: "Pretendard-Regular", size: labelFontSize)
                ?? UIFont.systemFont(ofSize: labelFontSize, weight: .regular)
            let valueFont = UIFont(name: "Pretendard-SemiBold", size: labelFontSize)
                ?? UIFont.systemFont(ofSize: labelFontSize, weight: .semibold)
            let titleWidth = (GarmentMeasurementText.shortTitle(definition) as NSString)
                .size(withAttributes: [.font: titleFont]).width
            let valueWidth = (visibleMeasurementValue(value) as NSString)
                .size(withAttributes: [.font: valueFont]).width
            let width = ceil(titleWidth + valueWidth + 12)
            let labelSize = CGSize(width: min(max(60, width), size.width - 8), height: labelHeight)
            return .init(definition: definition, value: value, start: start, end: end,
                labelCenter: nil, labelSize: labelSize, isCallout: false)
        }
        return positionedAnnotations(items, in: size)
    }

    private func positionedAnnotations(_ items: [Annotation], in size: CGSize) -> [Annotation] {
        let physicalMarkers = handles.map { point in
            let center = screenPoint(previewPoint(point), size: size)
            let diameter: CGFloat = 18
            return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                width: diameter, height: diameter)
        }
        // Protect derived/projected dots as well as physical handles, including
        // during a drag. Projected segments stay engine-owned until recalculation.
        let endpointMarkers = items.flatMap { item in
            [item.start, item.end].map {
                CGRect(x: $0.x - 6, y: $0.y - 6, width: 12, height: 12)
            }
        }
        let markers = physicalMarkers + endpointMarkers
        var occupied: [CGRect] = []
        if magnifiedPoint(in: size) != nil {
            occupied.append(magnifierRect(in: size).insetBy(dx: -4, dy: -4))
        }
        // Reserve the same base-image region before and after the first pinch.
        // The reset button appearing must not reposition a measurement label.
        if showsEnlargeControl || allowsViewportZoom {
            occupied.append(CGRect(x: size.width - 56, y: 8, width: 48, height: 48))
        }
        return items.map { item in
            let placement = GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: item.start, end: item.end,
                labelSize: item.labelSize, imageSize: size, occupied: occupied, markers: markers)
            if let placement { occupied.append(placement.rect) }
            return .init(definition: item.definition, value: item.value, start: item.start, end: item.end,
                labelCenter: placement.map { .init(x: $0.rect.midX, y: $0.rect.midY) },
                labelSize: item.labelSize, isCallout: placement?.isCallout ?? false)
        }
    }

    private func previewPoint(_ point: GarmentLandmark) -> ImagePoint {
        if let drag, drag.id == point.id { return drag.current }
        return point.point
    }

    private func screenPoint(_ point: ImagePoint, size: CGSize) -> CGPoint {
        GarmentPhotoGeometry.screenPoint(point, photoSize: size, orientation: snapshot.frame.orientation,
            displayCrop: displayCrop)
    }

    private func visibleMeasurementValue(_ value: MeasurementValue) -> String {
        GarmentMeasurementText.value(value).replacingOccurrences(of: " cm", with: "cm")
    }

    private func magnifierRect(in size: CGSize) -> CGRect {
        let point = drag.flatMap { moving in
            displayedPointCenters[moving.id] ?? screenPoint(moving.current, size: size)
        } ?? .zero
        let initialRect = lockedMagnifierRect ?? MeasurementMagnifierPlacement.rect(
            photoSize: size, point: point,
            windowCenter: windowCenterInPhoto ?? CGPoint(x: size.width / 2, y: size.height / 2))
        // The grab's quadrant stays locked. A sheet can only raise the loupe's
        // display frame; it never changes the source point or the photo viewport.
        return MeasurementMagnifierPlacement.avoidingBottomOcclusion(initialRect,
            photoSize: size, bottomInset: magnifierBottomInset)
    }
}

private struct MeasurementPhotoAccessibilityActions: ViewModifier {
    let isEnabled: Bool
    let onAdjust: (AccessibilityAdjustmentDirection) -> Void
    let onReset: () -> Void
    let onScroll: (Edge) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAdjustableAction(onAdjust)
                .accessibilityAction(named: "사진을 원래 크기로 보기", onReset)
                .accessibilityScrollAction(onScroll)
        } else {
            content
        }
    }
}

/// Each point owns the nearby half of overlapping hit circles, so a small
/// visible marker can never be covered by a neighbour's invisible touch area.
private struct MeasurementPointHitShape: Shape {
    let neighborOffsets: [CGPoint]
    func path(in rect: CGRect) -> Path {
        let vertices = GarmentPhotoGeometry.pointHitPolygon(size: rect.size, neighborOffsets: neighborOffsets)
        return Path { path in
            guard let first = vertices.first else { return }
            path.move(to: CGPoint(x: rect.minX + first.x, y: rect.minY + first.y))
            for point in vertices.dropFirst() {
                path.addLine(to: CGPoint(x: rect.minX + point.x, y: rect.minY + point.y))
            }
            path.closeSubpath()
        }
    }
}

private struct MeasurementGlassCapsule: ViewModifier {
    let reduceTransparency: Bool
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.14), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 0.75))
        } else {
            content.glassEffect(.clear.tint(.black.opacity(0.3)).interactive(), in: Capsule())
        }
    }
}

/// Figma's display-only labels use Labels/Tertiary, without an interactive
/// glass edge. Keep an opaque alternative when Reduce Transparency is enabled.
private struct MeasurementValueCapsule: ViewModifier {
    let reduceTransparency: Bool
    func body(content: Content) -> some View {
        content.background(
            Color(red: 60.0 / 255, green: 60.0 / 255, blue: 67.0 / 255)
                .opacity(reduceTransparency ? 1 : 0.3), in: Capsule())
    }
}

enum GarmentPointName {
    static func title(_ id: String) -> String {
        switch id {
        case "neck_center": "목 중앙점"
        case "top_length_start": "총장 상단점"
        case "top_length_hem": "목옆 기준 밑단 교점"
        case "front_length_start": "앞판 총장 상단점"
        case "waist_front_center": "앞허리 중앙점"
        case "thigh_right": "오른쪽 허벅지점"
        case "neck_left": "왼쪽 목점"
        case "neck_right": "오른쪽 목점"
        case "shoulder_left": "왼쪽 어깨점"
        case "shoulder_right": "오른쪽 어깨점"
        case "armpit_left": "왼쪽 겨드랑이점"
        case "armpit_right": "오른쪽 겨드랑이점"
        case "sleeve_end_left": "왼쪽 소매 끝점"
        case "sleeve_end_right": "오른쪽 소매 끝점"
        case "hem_left": "왼쪽 밑단점"
        case "hem_center": "밑단 중앙점"
        case "hem_right": "오른쪽 밑단점"
        case "waist_left": "왼쪽 허리점"
        case "waist_right": "오른쪽 허리점"
        case "crotch": "가랑이점"
        case "hem_left_outer": "왼쪽 바깥 밑단점"
        case "hem_left_inner": "왼쪽 안쪽 밑단점"
        case "hem_right_outer": "오른쪽 바깥 밑단점"
        case "hem_right_inner": "오른쪽 안쪽 밑단점"
        default: id
        }
    }
}

nonisolated enum GarmentPhotoGeometry {
    /// Rendering and label exclusion share the same compact, aspect-preserving
    /// rectangle. Small photos reduce both the inset and loupe safely.
    static func magnifierRect(photoSize size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let x = min(20, max(0, size.width - 1) / 2)
        let y = min(19, max(0, size.height - 1) / 2)
        let scale = min(1, max(0, size.width - x * 2) / 76, max(0, size.height - y * 2) / 107)
        return CGRect(x: x, y: y, width: 76 * scale, height: 107 * scale)
    }

    /// Clip a circular hit region at the perpendicular bisectors between this
    /// marker and its neighbours. All output vertices use local view coordinates.
    static func pointHitPolygon(size: CGSize, neighborOffsets: [CGPoint]) -> [CGPoint] {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return [] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        var vertices = (0..<72).map { index in
            let angle = CGFloat(index) * .pi / 36
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        for neighbor in neighborOffsets {
            let distanceSquared = neighbor.x * neighbor.x + neighbor.y * neighbor.y
            // Far neighbours cannot intersect the hit circle. Coincident
            // markers share one location and retain the ordinary drawing order.
            guard neighbor.x.isFinite, neighbor.y.isFinite,
                  distanceSquared > 0, distanceSquared < 4 * radius * radius else { continue }
            let limit = distanceSquared / 2
            var clipped: [CGPoint] = []
            guard var previous = vertices.last else { break }
            var previousDistance = previous.x * neighbor.x + previous.y * neighbor.y - limit
            for current in vertices {
                let currentDistance = current.x * neighbor.x + current.y * neighbor.y - limit
                if (previousDistance <= 0) != (currentDistance <= 0) {
                    let fraction = previousDistance / (previousDistance - currentDistance)
                    clipped.append(CGPoint(x: previous.x + (current.x - previous.x) * fraction,
                        y: previous.y + (current.y - previous.y) * fraction))
                }
                if currentDistance <= 0 { clipped.append(current) }
                previous = current
                previousDistance = currentDistance
            }
            vertices = clipped
        }
        return vertices.map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) }
    }

    struct SegmentLabelPlacement {
        let rect: CGRect
        let isCallout: Bool
    }

    /// Place a horizontal caption beside its own segment, preferring the upper
    /// side. Vertical lines prefer the garment's outer side. Short or obstructed
    /// segments use a nearby callout rather than covering their endpoints.
    static func segmentLabelPlacement(start: CGPoint, end: CGPoint, labelSize: CGSize,
                                      imageSize: CGSize, occupied: [CGRect], markers: [CGRect] = []) -> SegmentLabelPlacement? {
        guard [start.x, start.y, end.x, end.y, labelSize.width, labelSize.height,
               imageSize.width, imageSize.height].allSatisfy(\.isFinite),
              labelSize.width > 0, labelSize.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let ordered = start.x < end.x || (start.x == end.x && start.y <= end.y)
        let a = ordered ? start : end, b = ordered ? end : start
        let length = hypot(b.x - a.x, b.y - a.y)
        let tangent = length > 0 ? CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length) : CGPoint(x: 1, y: 0)
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        var normal = CGPoint(x: tangent.y, y: -tangent.x)
        if abs(tangent.x) < 0.001 {
            normal = CGPoint(x: middle.x < imageSize.width / 2 ? -1 : 1, y: 0)
        }
        let offset = abs(normal.x) * labelSize.width / 2 + abs(normal.y) * labelSize.height / 2 + 4
        let preferred = CGPoint(x: middle.x + normal.x * offset, y: middle.y + normal.y * offset)
        let touchSize = CGSize(width: labelSize.width, height: max(44, labelSize.height))
        let bounds = CGRect(origin: .zero, size: imageSize).insetBy(dx: 4, dy: 4)
        let along = abs(tangent.x) * labelSize.width + abs(tangent.y) * labelSize.height

        if length >= along + 24 {
            let margin = (along / 2 + 12) / length
            // Keep the value between its own endpoints, starting at the middle.
            // If its upper side is blocked, try the other side before a callout.
            for side: CGFloat in [1, -1] {
                for fraction: CGFloat in [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8, 0.15, 0.85]
                    where fraction >= margin && fraction <= 1 - margin {
                    let center = CGPoint(x: a.x + (b.x - a.x) * fraction + normal.x * offset * side,
                        y: a.y + (b.y - a.y) * fraction + normal.y * offset * side)
                    let rect = CGRect(x: center.x - touchSize.width / 2, y: center.y - touchSize.height / 2,
                        width: touchSize.width, height: touchSize.height)
                    let visible = CGRect(x: rect.minX, y: rect.midY - labelSize.height / 2,
                        width: rect.width, height: labelSize.height)
                    if bounds.contains(rect), !occupied.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(rect) }),
                       !markers.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(visible) }) {
                        return .init(rect: rect, isCallout: false)
                    }
                }
            }
        }
        return labelPlacement(near: preferred, labelSize: touchSize, imageSize: imageSize,
            occupied: occupied, markers: markers, visibleLabelHeight: labelSize.height)
            .map { .init(rect: $0, isCallout: true) }
    }

    /// Rectangle of the complete oriented image behind the visible viewport.
    /// Cropping is display-only: no JPEG, landmark, depth or intrinsics rewrite.
    static func photoRect(photoSize: CGSize, displayCrop: PhotoDisplayCrop = .full) -> CGRect {
        guard displayCrop.isValid, photoSize.width.isFinite, photoSize.height.isFinite,
              photoSize.width > 0, photoSize.height > 0 else { return .zero }
        let fullSize = CGSize(width: photoSize.width / CGFloat(displayCrop.width),
            height: photoSize.height / CGFloat(displayCrop.height))
        return CGRect(x: -CGFloat(displayCrop.x) * fullSize.width,
            y: -CGFloat(displayCrop.y) * fullSize.height,
            width: fullSize.width, height: fullSize.height)
    }

    static func screenPoint(_ original: ImagePoint, photoSize: CGSize, orientation: ImageOrientation,
                            displayCrop: PhotoDisplayCrop = .full) -> CGPoint {
        let display = ImageCoordinateTransform.originalToDisplay(original, orientation: orientation)
        let rect = photoRect(photoSize: photoSize, displayCrop: displayCrop)
        return .init(x: rect.minX + CGFloat(display.x) * rect.width,
            y: rect.minY + CGFloat(display.y) * rect.height)
    }

    static func originalPoint(at screen: CGPoint, photoSize: CGSize, orientation: ImageOrientation,
                              displayCrop: PhotoDisplayCrop = .full) -> ImagePoint? {
        guard photoSize.width > 0, photoSize.height > 0,
              photoSize.width.isFinite, photoSize.height.isFinite, screen.x.isFinite, screen.y.isFinite,
              displayCrop.isValid else { return nil }
        // Clamp in the visible viewport before undoing its crop and rotation.
        // A drag beyond an edge must not move a point into the hidden scene.
        let display = ImagePoint(x: displayCrop.x + min(1, max(0, screen.x / photoSize.width)) * displayCrop.width,
            y: displayCrop.y + min(1, max(0, screen.y / photoSize.height)) * displayCrop.height)
        let original = ImageCoordinateTransform.displayToOriginal(display, orientation: orientation)
        return .init(x: min(Double(1).nextDown, max(0, original.x)),
            y: min(Double(1).nextDown, max(0, original.y)))
    }

    struct MagnifierLayout {
        let imageSize: CGSize
        let imageOrigin: CGPoint
        let crosshair: CGPoint
    }

    static func magnifier(displayPoint: ImagePoint, photoSize: CGSize, loupeSize: CGSize,
                          displayCrop: PhotoDisplayCrop = .full, magnification: CGFloat = 3) -> MagnifierLayout {
        let scale: CGFloat = magnification.isFinite ? min(12, max(1, magnification)) : 3
        let fullPhoto = photoRect(photoSize: photoSize, displayCrop: displayCrop).size
        let enlarged = CGSize(width: fullPhoto.width * scale, height: fullPhoto.height * scale)
        let point = CGPoint(x: displayPoint.x * enlarged.width, y: displayPoint.y * enlarged.height)
        let center = CGPoint(x: loupeSize.width / 2, y: loupeSize.height / 2)
        let origin = CGPoint(x: center.x - point.x, y: center.y - point.y)
        return .init(imageSize: enlarged, imageOrigin: origin,
            crosshair: center)
    }

    /// Reserve full caption/control touch areas. Point markers only obstruct
    /// the visible capsule: point handles win touches in its transparent padding.
    /// If no space remains, omit the caption instead of covering its endpoints.
    static func labelPlacement(near middle: CGPoint, labelSize: CGSize,
                               imageSize: CGSize, occupied: [CGRect], markers: [CGRect] = [],
                               visibleLabelHeight: CGFloat? = nil) -> CGRect? {
        let maxX = imageSize.width - labelSize.width - 4, maxY = imageSize.height - labelSize.height - 4
        guard maxX >= 4, maxY >= 4 else { return nil }
        let desiredX = min(max(4, middle.x - labelSize.width / 2), maxX)
        let desiredY = min(max(4, middle.y - labelSize.height / 2), maxY)
        let visibleHeight = visibleLabelHeight ?? labelSize.height
        let padding = (labelSize.height - visibleHeight) / 2
        let xs = ([desiredX, 4, maxX] + (occupied + markers).flatMap { [$0.minX - labelSize.width - 4, $0.maxX + 4] })
            .filter { $0 >= 4 && $0 <= maxX }
        let controlEdges: [CGFloat] = occupied.flatMap { [$0.minY - labelSize.height - 4, $0.maxY + 4] }
        let markerEdges: [CGFloat] = markers.flatMap { [$0.minY - labelSize.height - 4 + padding, $0.maxY + 4 - padding] }
        let yCandidates: [CGFloat] = [desiredY, 4, maxY] + controlEdges + markerEdges
        let ys = yCandidates.filter { $0 >= 4 && $0 <= maxY }
        var best: CGRect?, bestDistance = CGFloat.infinity
        for y in ys {
            for x in xs {
                let distance = pow(x - desiredX, 2) + pow(y - desiredY, 2)
                guard distance < bestDistance else { continue }
                let candidate = CGRect(x: x, y: y, width: labelSize.width, height: labelSize.height)
                guard !occupied.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(candidate) }) else { continue }
                let visible = CGRect(x: x, y: y + padding, width: labelSize.width, height: visibleHeight)
                guard !markers.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(visible) }) else { continue }
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }
}
