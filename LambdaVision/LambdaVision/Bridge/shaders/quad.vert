#version 450
// Solid-color 2D quad. Push constants pass rect in NDC + rgba color.
// Vertex layout: 6 verts (two CCW triangles) generated from gl_VertexIndex.

layout(push_constant) uniform PC {
    vec4 rect_ndc;  // (x0, y0, x1, y1) in clip space, y flipped from xash 2D coords
    vec4 color;
} pc;

layout(location = 0) out vec4 vColor;

void main() {
    // 0,1,2 = first tri (tl, bl, br); 3,4,5 = second tri (tl, br, tr)
    vec2 corners[6] = vec2[](
        vec2(pc.rect_ndc.x, pc.rect_ndc.y),  // tl
        vec2(pc.rect_ndc.x, pc.rect_ndc.w),  // bl
        vec2(pc.rect_ndc.z, pc.rect_ndc.w),  // br
        vec2(pc.rect_ndc.x, pc.rect_ndc.y),  // tl
        vec2(pc.rect_ndc.z, pc.rect_ndc.w),  // br
        vec2(pc.rect_ndc.z, pc.rect_ndc.y)   // tr
    );
    gl_Position = vec4(corners[gl_VertexIndex], 0.0, 1.0);
    vColor = pc.color;
}
