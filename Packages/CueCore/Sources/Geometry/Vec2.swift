/// 2D vector in table coordinates (metres). Origin = foot-left cushion-nose corner,
/// +x along the long axis toward the head rail, +y across the table.
public struct Vec2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static let zero = Vec2(0, 0)

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }
    public var normalized: Vec2 { let l = length; return l == 0 ? .zero : Vec2(x / l, y / l) }
    /// Rotated +90° (counter-clockwise).
    public var perpendicular: Vec2 { Vec2(-y, x) }
    public var angle: Double { atan2Approx(y, x) }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    /// z-component of the 3D cross product.
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public func distance(to o: Vec2) -> Double { (self - o).length }
    public func rotated(by radians: Double) -> Vec2 {
        let c = cosApprox(radians), s = sinApprox(radians)
        return Vec2(x * c - y * s, x * s + y * c)
    }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public static func * (k: Double, a: Vec2) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public static func / (a: Vec2, k: Double) -> Vec2 { Vec2(a.x / k, a.y / k) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    public static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    public var description: String { "(\(x), \(y))" }
}

#if canImport(Darwin)
import Darwin
@inline(__always) func atan2Approx(_ y: Double, _ x: Double) -> Double { Darwin.atan2(y, x) }
@inline(__always) func cosApprox(_ a: Double) -> Double { Darwin.cos(a) }
@inline(__always) func sinApprox(_ a: Double) -> Double { Darwin.sin(a) }
#else
import Glibc
@inline(__always) func atan2Approx(_ y: Double, _ x: Double) -> Double { Glibc.atan2(y, x) }
@inline(__always) func cosApprox(_ a: Double) -> Double { Glibc.cos(a) }
@inline(__always) func sinApprox(_ a: Double) -> Double { Glibc.sin(a) }
#endif
