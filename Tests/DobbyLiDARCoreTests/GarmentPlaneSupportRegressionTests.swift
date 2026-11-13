import Foundation
import XCTest
@testable import DobbyLiDARCore

final class GarmentPlaneSupportRegressionTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Sample: Decodable { var raw: ImagePoint; var position: Point3D }
        var baselineInliers: Int
        var requiredInliers: Int
        var samples: [Sample]
    }

    /// Point-cloud replay deliberately does not pretend to validate the missing
    /// source mask/calibration or physical centimetre accuracy.
    func testExportedJacketPointCloudRetainsSupportedCandidateWhenTLSLosesInliers() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PlaneSupportRegression", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let samples = fixture.samples.map { GarmentPlaneGeometry.Sample(position: $0.position, raw: $0.raw) }
        var bounds = GarmentPlaneGeometry.Bounds()
        for sample in samples { bounds.include(sample.raw) }
        let trace = GarmentPlaneDiagnosticTrace()
        let plane = try GarmentPlaneGeometry.fitSamples(samples, interiorCount: samples.count,
            inRangeInteriorCount: samples.count, interiorBounds: bounds, trace: trace)
        XCTAssertEqual(GarmentPlaneGeometry.candidateIterations, 1024)
        XCTAssertEqual(GarmentPlaneGeometry.minimumInlierFraction, 0.75)
        XCTAssertEqual(GarmentPlaneGeometry.inlierToleranceMeters, 0.010)
        XCTAssertEqual(samples.count, 617)
        XCTAssertEqual(fixture.baselineInliers, 448)
        XCTAssertGreaterThanOrEqual(plane.quality.inlierCount, fixture.requiredInliers)
        XCTAssertEqual(plane.quality.inlierCount, trace.initialInlierCount)
        let proposal = try XCTUnwrap(trace.refinementProposals.first)
        XCTAssertLessThan(proposal.proposedInliers, proposal.beforeInliers)
        XCTAssertFalse(proposal.adopted)
        XCTAssertLessThanOrEqual(plane.quality.orthogonalRMSMeters, 0.008)
        XCTAssertGreaterThanOrEqual(plane.quality.horizontalCoverage, 0.6)
        XCTAssertGreaterThanOrEqual(plane.quality.verticalCoverage, 0.6)
        XCTAssertGreaterThanOrEqual(plane.quality.viewingRayCosine, 0.35)
        let repeatPlane = try GarmentPlaneGeometry.fitSamples(samples, interiorCount: samples.count,
            inRangeInteriorCount: samples.count, interiorBounds: bounds)
        XCTAssertEqual(plane.quality, repeatPlane.quality)
        XCTAssertEqual(plane.offset, repeatPlane.offset)
    }
}
