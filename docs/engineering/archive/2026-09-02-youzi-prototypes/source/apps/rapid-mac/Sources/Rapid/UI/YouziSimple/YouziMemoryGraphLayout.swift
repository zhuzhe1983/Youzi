import CoreGraphics
import Foundation

/// A deterministic, normalized point in the Know Me graph. `z` is visual
/// depth only; the graph remains an accessible SwiftUI surface rather than a
/// SceneKit world.
struct YouziMemoryGraphPosition: Equatable, Sendable {
    let nodeID: UUID
    let x: Double
    let y: Double
    let z: Double
}

struct YouziMemoryGraphProjection: Equatable, Sendable {
    let point: CGPoint
    let depth: Double
    let scale: Double
}

enum YouziMemoryGraphLayout {
    /// Produces stable positions independent of query/SQLite row order. Degree
    /// gently pulls connected nodes toward the center while UUID bytes provide
    /// deterministic angular separation without Swift's randomized `Hasher`.
    static func positions(
        nodes: [YouziMemoryNodeRecord],
        edges: [YouziMemoryEdgeRecord]
    ) -> [UUID: YouziMemoryGraphPosition] {
        let ordered = nodes.sorted { stableID($0.id) < stableID($1.id) }
        guard !ordered.isEmpty else { return [:] }

        var degree: [UUID: Int] = [:]
        for edge in edges {
            degree[edge.sourceNodeID, default: 0] += 1
            degree[edge.targetNodeID, default: 0] += 1
        }
        let goldenAngle = Double.pi * (3 - sqrt(5.0))
        var result: [UUID: YouziMemoryGraphPosition] = [:]
        for (index, node) in ordered.enumerated() {
            let bytes = bytes(of: node.id)
            let jitter = Double(bytes[0]) / 255.0 * 0.42
            let angle = Double(index) * goldenAngle + jitter
            let normalizedIndex = sqrt((Double(index) + 0.75) / Double(ordered.count))
            let connectivityPull = min(0.24, Double(degree[node.id, default: 0]) * 0.025)
            let radius = max(0.12, normalizedIndex * 0.9 - connectivityPull)
            let zSeed = (Double(bytes[14]) * 256 + Double(bytes[15])) / 65_535.0
            let z = (zSeed * 2 - 1) * 0.72
            result[node.id] = .init(
                nodeID: node.id,
                x: cos(angle) * radius,
                y: sin(angle) * radius * 0.72,
                z: z
            )
        }
        return result
    }

    static func project(
        _ position: YouziMemoryGraphPosition,
        yaw: Double,
        zoom: Double,
        pan: CGSize,
        viewport: CGSize
    ) -> YouziMemoryGraphProjection {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        let rotatedX = position.x * cosine + position.z * sine
        let rotatedZ = -position.x * sine + position.z * cosine
        let clampedZoom = min(max(zoom, 0.6), 2.4)
        let radius = max(1, min(viewport.width, viewport.height) * 0.43 * clampedZoom)
        let depthScale = 0.84 + (rotatedZ + 1) * 0.12
        return .init(
            point: CGPoint(
                x: viewport.width / 2 + rotatedX * radius + pan.width,
                y: viewport.height / 2 + position.y * radius + pan.height
            ),
            depth: rotatedZ,
            scale: min(max(depthScale, 0.72), 1.12)
        )
    }

    private static func bytes(of id: UUID) -> [UInt8] {
        withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    private static func stableID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
