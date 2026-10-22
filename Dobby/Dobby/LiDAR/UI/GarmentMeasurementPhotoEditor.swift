import SwiftUI
import UIKit

/// All overlays use the aspect-fit photograph's rectangle. Storage and depth
/// sampling continue to use the original, unrotated sensor coordinates.
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
    let onSelect: (MeasurementDefinition) -> Void
    let onEnlarge: () -> Void
    let onMove: (String, ImagePoint) -> Void
    let onEditingChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var labelHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var labelFontSize: CGFloat = 12
    @State private var selectedPointID: String?
    @State private var drag: PointDrag?
    @GestureState private var gestureIsActive = false

    private struct PointDrag {
        let id: String
        let start: ImagePoint
        let annotations: [Annotation]
        var current: ImagePoint
    }

    private var handles: [GarmentLandmark] {
        editableLandmarks.points.filter { $0.isVisible && $0.point.isValid }
    }

    private var selectedPoint: GarmentLandmark? {
        handles.first { $0.id == selectedPointID } ?? handles.first { point in
            definitions.first?.landmarkIDs.contains(point.id) == true
        } ?? handles.first
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let annotations = annotations(in: size)
            ZStack(alignment: .topLeading) {
                photograph(size: size)
                measurementLines(annotations)
                GlassEffectContainer(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if showLabels {
                            ForEach(annotations) { item in
                                if let center = item.labelCenter {
                                    measurementLabel(item).position(center)
                                }
                            }
                        }
                    }.frame(width: size.width, height: size.height)
                }
                // The small markers sit above labels. Their larger invisible
                // touch regions take priority when a finger grabs nearby.
                ForEach(handles) { point in
                    pointHandle(point, size: size)
                        .position(screenPoint(previewPoint(point), size: size))
                }
                if let image, let point = selectedPoint {
                    let loupe = magnifierRect(in: size)
                    magnifier(image: image, point: point, photoSize: size)
                        .position(x: loupe.midX, y: loupe.midY).allowsHitTesting(false)
                }
                if showsEnlargeControl {
                    Button(action: onEnlarge) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .modifier(MeasurementGlassCapsule(reduceTransparency: reduceTransparency))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.white)
                        .disabled(image == nil)
                        .position(x: size.width - 30, y: 30)
                        .accessibilityLabel("촬영 사진 확대")
                        .accessibilityIdentifier("enlargeGarmentPhoto")
                }
            }.frame(width: size.width, height: size.height).clipped()
                .coordinateSpace(name: "garmentPhoto")
                .onChange(of: size) { _, _ in
                    // A rotation/window resize invalidates the cached display
                    // geometry, so finish without committing that touch preview.
                    if drag != nil { drag = nil; onEditingChanged(false) }
                }
        }
        .aspectRatio(SnapshotPresentation.aspectRatio(for: snapshot), contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentMeasurementPhoto")
        .onChange(of: gestureIsActive) { _, active in
            // Interrupted touches (for example, app backgrounding) don't always
            // call onEnded. Discard that preview and unblock confirmation.
            if !active, drag != nil {
                drag = nil
                onEditingChanged(false)
            }
        }
        .onDisappear { onEditingChanged(false) }
    }

    private func photograph(size: CGSize) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .accessibilityLabel("촬영한 옷과 측정점")
            } else {
                ContentUnavailableView("사진을 불러올 수 없어요", systemImage: "photo")
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    private func measurementLines(_ annotations: [Annotation]) -> some View {
        Canvas { context, size in
            for item in annotations {
                var path = Path()
                path.move(to: item.start)
                path.addLine(to: item.end)
                context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 3)
                context.stroke(path, with: .color(.white.opacity(0.95)),
                    style: .init(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))
                // Spatially derived and projected endpoints remain indicators,
                // never draggable substitutes for their physical source points.
                for endpoint in [item.start, item.end] {
                    let marker = Path(ellipseIn: CGRect(x: endpoint.x - 3, y: endpoint.y - 3, width: 6, height: 6))
                    context.fill(marker, with: .color(.white))
                }
                let middle = CGPoint(x: (item.start.x + item.end.x) / 2, y: (item.start.y + item.end.y) / 2)
                if showLabels, item.isCallout, let center = item.labelCenter {
                    let labelRect = CGRect(x: center.x - item.labelSize.width / 2,
                        y: center.y - item.labelSize.height / 2,
                        width: item.labelSize.width, height: item.labelSize.height)
                    let edge = CGPoint(x: min(labelRect.maxX, max(labelRect.minX, middle.x)),
                        y: min(labelRect.maxY, max(labelRect.minY, middle.y)))
                    var leader = Path()
                    leader.move(to: middle)
                    leader.addLine(to: edge)
                    context.stroke(leader, with: .color(.black.opacity(0.45)), lineWidth: 2)
                    context.stroke(leader, with: .color(.white.opacity(0.55)), lineWidth: 0.75)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func measurementLabel(_ item: Annotation) -> some View {
        Button { onSelect(item.definition) } label: {
            HStack(spacing: 3) {
                Text(GarmentMeasurementText.shortTitle(item.definition)).foregroundStyle(.white.opacity(0.95))
                    .font(.system(size: labelFontSize, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
                Text(drag != nil || isRecalculating ? "…" : visibleMeasurementValue(item.value))
                    .font(.system(size: labelFontSize, weight: .regular))
                    .monospacedDigit().fixedSize(horizontal: true, vertical: false)
            }.font(.system(size: labelFontSize, weight: .regular)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 0.75, y: 0.5)
                .lineLimit(1).padding(.horizontal, 6)
                .frame(width: item.labelSize.width, height: item.labelSize.height)
                .modifier(MeasurementGlassCapsule(reduceTransparency: reduceTransparency))
                .frame(height: max(44, item.labelSize.height))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(item.definition.title), \(drag != nil || isRecalculating ? "재계산 중" : GarmentMeasurementText.value(item.value))")
            .accessibilityHint("측정 항목 상세 보기")
            .accessibilityIdentifier("garmentMeasurementLabel_\(item.id)")
    }

    private func pointHandle(_ point: GarmentLandmark, size: CGSize) -> some View {
        let selected = selectedPoint?.id == point.id
        let center = screenPoint(previewPoint(point), size: size)
        let neighbors = handles.filter { $0.id != point.id }.map {
            let other = screenPoint(previewPoint($0), size: size)
            return CGPoint(x: other.x - center.x, y: other.y - center.y)
        }
        return Button { selectedPointID = point.id } label: {
            ZStack {
                Circle().fill(.black.opacity(0.35)).frame(width: 12.5, height: 12.5)
                if selected {
                    Circle().fill(GarmentCaptureStyle.accent.opacity(0.25)).frame(width: 18, height: 18)
                    Circle().stroke(GarmentCaptureStyle.accent.opacity(0.8), lineWidth: 1)
                        .frame(width: 18, height: 18)
                }
                Circle().fill(.white).frame(width: 8.5, height: 8.5)
            }.shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: selected)
                .frame(width: 56, height: 56)
                .contentShape(MeasurementPointHitShape(neighborOffsets: neighbors))
        }.buttonStyle(.plain).disabled(!isEnabled)
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("garmentPhoto"))
                .updating($gestureIsActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard isEnabled else { return }
                    if let drag, drag.id != point.id { return }
                    if drag == nil {
                        selectedPointID = point.id
                        drag = .init(id: point.id, start: point.point,
                            annotations: annotations(in: size), current: point.point)
                        onEditingChanged(true)
                    }
                    guard let currentDrag = drag else { return }
                    // Use translation from the original point rather than the
                    // finger's initial hit position, so grabbing its ring never jumps.
                    let start = screenPoint(currentDrag.start, size: size)
                    let location = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                    if let original = GarmentPhotoGeometry.originalPoint(at: location, photoSize: size,
                        orientation: snapshot.frame.orientation) {
                        drag?.current = original
                    }
                }.onEnded { _ in
                    guard let completed = drag, completed.id == point.id else { return }
                    onMove(completed.id, completed.current)
                    drag = nil
                    onEditingChanged(false)
                })
            .accessibilityLabel(GarmentPointName.title(point.id))
            .accessibilityValue(String(format: "x %.4f, y %.4f", previewPoint(point).x, previewPoint(point).y))
            .accessibilityHint("선택하면 왼쪽 위에서 확대됩니다. 끌어서 위치를 바꾸거나 위치 이동 동작을 사용하세요")
            .accessibilityAction(named: "왼쪽으로 이동") { nudge(point, dx: -2, dy: 0, size: size) }
            .accessibilityAction(named: "오른쪽으로 이동") { nudge(point, dx: 2, dy: 0, size: size) }
            .accessibilityAction(named: "위로 이동") { nudge(point, dx: 0, dy: -2, size: size) }
            .accessibilityAction(named: "아래로 이동") { nudge(point, dx: 0, dy: 2, size: size) }
            .accessibilityIdentifier("garmentMeasurementPoint_\(point.id)")
    }

    private func nudge(_ point: GarmentLandmark, dx: CGFloat, dy: CGFloat, size: CGSize) {
        guard isEnabled else { return }
        selectedPointID = point.id
        let current = screenPoint(point.point, size: size)
        guard let original = GarmentPhotoGeometry.originalPoint(at: .init(x: current.x + dx, y: current.y + dy),
            photoSize: size, orientation: snapshot.frame.orientation) else { return }
        onMove(point.id, original)
    }

    private func magnifier(image: UIImage, point: GarmentLandmark, photoSize: CGSize) -> some View {
        let loupeSize = magnifierRect(in: photoSize).size
        let display = ImageCoordinateTransform.originalToDisplay(previewPoint(point), orientation: snapshot.frame.orientation)
        let layout = GarmentPhotoGeometry.magnifier(displayPoint: display, photoSize: photoSize, loupeSize: loupeSize)
        // A bounded canvas avoids a three-times-larger SwiftUI Image's
        // layout/accessibility bounds leaking outside the clipped inset.
        return Canvas { context, _ in
            context.draw(context.resolve(Image(uiImage: image)),
                in: CGRect(origin: layout.imageOrigin, size: layout.imageSize))
            let marker = CGRect(x: layout.crosshair.x - 12, y: layout.crosshair.y - 12, width: 24, height: 24)
            context.fill(Path(ellipseIn: marker), with: .color(.black.opacity(0.2)))
            context.stroke(Path(ellipseIn: marker), with: .color(.white), lineWidth: 1)
            var cross = Path()
            cross.move(to: .init(x: layout.crosshair.x - 12, y: layout.crosshair.y))
            cross.addLine(to: .init(x: layout.crosshair.x + 12, y: layout.crosshair.y))
            cross.move(to: .init(x: layout.crosshair.x, y: layout.crosshair.y - 12))
            cross.addLine(to: .init(x: layout.crosshair.x, y: layout.crosshair.y + 12))
            context.stroke(cross, with: .color(.white), lineWidth: 1)
        }.frame(width: loupeSize.width, height: loupeSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            // The image is deliberately three times larger than the viewport.
            // Expose only the bounded loupe, never the clipped image's AX frame.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(GarmentPointName.title(point.id)) 확대, 3배")
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
            // Match the medium title and regular monospaced value separately,
            // using the same compact unit spacing as the visible capsule.
            let titleFont = UIFont.systemFont(ofSize: labelFontSize, weight: .medium)
            let valueFont = UIFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .regular)
            let titleWidth = (GarmentMeasurementText.shortTitle(definition) as NSString)
                .size(withAttributes: [.font: titleFont]).width
            let valueWidth = (visibleMeasurementValue(value) as NSString)
                .size(withAttributes: [.font: valueFont]).width
            let width = ceil(titleWidth + valueWidth + 15) + 2
            let labelSize = CGSize(width: min(max(60, width), size.width - 8), height: labelHeight)
            return .init(definition: definition, value: value, start: start, end: end,
                labelCenter: nil, labelSize: labelSize, isCallout: false)
        }
        return positionedAnnotations(items, in: size)
    }

    private func positionedAnnotations(_ items: [Annotation], in size: CGSize) -> [Annotation] {
        let physicalMarkers = handles.map { point in
            let center = screenPoint(previewPoint(point), size: size)
            let diameter: CGFloat = selectedPoint?.id == point.id ? 24 : 18
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
        if image != nil, selectedPoint != nil {
            occupied.append(magnifierRect(in: size).insetBy(dx: -4, dy: -4))
        }
        if showsEnlargeControl {
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
        GarmentPhotoGeometry.screenPoint(point, photoSize: size, orientation: snapshot.frame.orientation)
    }

    private func visibleMeasurementValue(_ value: MeasurementValue) -> String {
        GarmentMeasurementText.value(value).replacingOccurrences(of: " cm", with: "cm")
    }

    private func magnifierRect(in size: CGSize) -> CGRect {
        // The design's 100 × 140 inset only shrinks for unusually small photos.
        // Rendering and label exclusion share this exact rectangle.
        let scale = min(1, max(0, size.width - 40) / 100, max(0, size.height - 38) / 140)
        return CGRect(x: 20, y: 19, width: 100 * scale, height: 140 * scale)
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
            content.glassEffect(.clear.tint(.black.opacity(0.06)).interactive(), in: Capsule())
        }
    }
}

enum GarmentPointName {
    static func title(_ id: String) -> String {
        switch id {
        case "neck_center": "목 중앙점"
        case "top_length_start": "총장 상단점"
        case "waist_front_center": "앞허리 중앙점"
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

    static func screenPoint(_ original: ImagePoint, photoSize: CGSize, orientation: ImageOrientation) -> CGPoint {
        let display = ImageCoordinateTransform.originalToDisplay(original, orientation: orientation)
        return .init(x: display.x * photoSize.width, y: display.y * photoSize.height)
    }

    static func originalPoint(at screen: CGPoint, photoSize: CGSize, orientation: ImageOrientation) -> ImagePoint? {
        guard photoSize.width > 0, photoSize.height > 0,
              photoSize.width.isFinite, photoSize.height.isFinite, screen.x.isFinite, screen.y.isFinite else { return nil }
        let display = ImagePoint(x: min(1, max(0, screen.x / photoSize.width)),
            y: min(1, max(0, screen.y / photoSize.height)))
        let original = ImageCoordinateTransform.displayToOriginal(display, orientation: orientation)
        return .init(x: min(Double(1).nextDown, max(0, original.x)),
            y: min(Double(1).nextDown, max(0, original.y)))
    }

    struct MagnifierLayout {
        let imageSize: CGSize
        let imageOrigin: CGPoint
        let crosshair: CGPoint
    }

    static func magnifier(displayPoint: ImagePoint, photoSize: CGSize, loupeSize: CGSize) -> MagnifierLayout {
        let scale: CGFloat = 3
        let enlarged = CGSize(width: photoSize.width * scale, height: photoSize.height * scale)
        let point = CGPoint(x: displayPoint.x * enlarged.width, y: displayPoint.y * enlarged.height)
        let center = CGPoint(x: min(max(point.x, loupeSize.width / 2), enlarged.width - loupeSize.width / 2),
            y: min(max(point.y, loupeSize.height / 2), enlarged.height - loupeSize.height / 2))
        let origin = CGPoint(x: loupeSize.width / 2 - center.x, y: loupeSize.height / 2 - center.y)
        return .init(imageSize: enlarged, imageOrigin: origin,
            crosshair: .init(x: point.x + origin.x, y: point.y + origin.y))
    }

    /// Reserve full caption/control touch areas. Point markers only obstruct
    /// the visible capsule: point handles win touches in its transparent padding.
    /// If no space remains, the value is still accessible in measurement details.
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
