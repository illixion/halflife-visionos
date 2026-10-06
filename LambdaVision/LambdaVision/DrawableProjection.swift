//
//  DrawableProjection.swift
//  LambdaVision
//
//  What the renderer reads back from the compositor's per-view projection.
//

import CompositorServices
import simd

extension LayerRenderer.Drawable {
    /// The view's frustum tangents — left, right, top, bottom, all positive —
    /// as `View.tangents` returned them before it was deprecated, read back
    /// from the compositor's own projection instead. The engine renders each
    /// eye through these (lambda_engine_set_projection_tangents), so they
    /// must describe exactly the frustum the compositor displays.
    ///
    /// The x and y rows of a perspective projection carry nothing but the
    /// frustum: x_ndc = sx·(x/−z) − ox, so the right edge (x/−z = tR, ndc 1)
    /// and the left (−tL, ndc −1) give tR = (1 + ox)/sx, tL = (1 − ox)/sx,
    /// and the same for y. The depth convention (reverse-Z, the layer's depth
    /// range) only touches the z row, which this ignores.
    nonisolated func frustumTangents(viewIndex: Int) -> SIMD4<Float> {
        let p = computeProjection(viewIndex: viewIndex)
        let sx = p.columns.0.x, sy = p.columns.1.y
        let ox = p.columns.2.x, oy = p.columns.2.y
        return SIMD4((1 - ox) / sx, (1 + ox) / sx, (1 + oy) / sy, (1 - oy) / sy)
    }
}
