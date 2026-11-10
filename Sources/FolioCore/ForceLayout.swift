import Foundation

/// The force simulation behind the 2D and 3D graph (#110, #133, #150): linked notes attract, all notes repel,
/// a gentle pull keeps everything near the center. Only the start positions and the nudge for two notes on the
/// same spot depend on the number of dimensions.
struct ForceSimulation<V: SIMD> where V.Scalar == Double {
    static var idealDistance: Double { 60 }

    private(set) var positions: [V]
    private let links: [(Int, Int)]
    /// Pushes two notes on exactly the same spot apart (index i, index j).
    private let nudge: (Int, Int) -> V

    init(positions: [V], links: [(Int, Int)], nudge: @escaping (Int, Int) -> V) {
        self.positions = positions
        self.links = links
        self.nudge = nudge
    }

    /// Big libraries: fewer rounds keep opening the graph fast.
    static func rounds(nodes n: Int, iterations: Int) -> Int {
        n > 800 ? min(iterations, 80) : n > 300 ? min(iterations, 150) : iterations
    }

    /// Edges as index pairs; self-links and unknown notes are dropped.
    static func links(_ edges: [(UUID, UUID)], in nodes: [UUID]) -> [(Int, Int)] {
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        return edges.compactMap { e in
            guard let a = index[e.0], let b = index[e.1], a != b else { return nil }
            return (a, b)
        }
    }

    mutating func run(rounds: Int) {
        var temperature = 40.0
        for _ in 0..<rounds {
            var displacement = repulsion()
            attract(&displacement)
            move(by: displacement, limit: temperature)
            temperature = max(temperature * 0.97, 1)
        }
    }

    private func repulsion() -> [V] {
        let n = positions.count
        var displacement = [V](repeating: .zero, count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                guard let push = push(between: i, and: j) else { continue }
                displacement[i] += push
                displacement[j] -= push
            }
        }
        return displacement
    }

    private func push(between i: Int, and j: Int) -> V? {
        var d = positions[i] - positions[j]
        var d2 = (d * d).sum()
        if d2 < 0.01 {
            d = nudge(i, j)
            d2 = (d * d).sum()
        }
        if d2 > 250_000 { return nil }   // far apart: no noticeable push
        return d * (Self.idealDistance * Self.idealDistance / d2)
    }

    private func attract(_ displacement: inout [V]) {
        for (a, b) in links {
            let d = positions[a] - positions[b]
            let length = max((d * d).sum().squareRoot(), 0.01)
            let pull = d * (length / Self.idealDistance)
            displacement[a] -= pull
            displacement[b] += pull
        }
    }

    private mutating func move(by displacement: [V], limit: Double) {
        for i in positions.indices {
            let d = displacement[i] - positions[i] * 0.06
            let length = max((d * d).sum().squareRoot(), 0.0001)
            positions[i] += d / length * min(length, limit)
        }
    }
}

extension GraphLayout {
    /// Golden-angle spiral: a stable, even start without randomness.
    static func spiralStart(_ i: Int) -> SIMD2<Double> {
        let r = 30 * sqrt(Double(i) + 0.5)
        let a = Double(i) * 2.399963
        return SIMD2(r * cos(a), r * sin(a))
    }

    /// Points on a Fibonacci sphere.
    static func sphereStart(_ i: Int, of n: Int) -> SIMD3<Double> {
        let y = n == 1 ? 0 : 1 - 2 * (Double(i) + 0.5) / Double(n)
        let r = (1 - y * y).squareRoot()
        let a = Double(i) * 2.399963
        return SIMD3(cos(a) * r, y, sin(a) * r) * (40 * Double(n).squareRoot())
    }
}
