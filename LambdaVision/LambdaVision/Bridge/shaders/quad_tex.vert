#version 450
// Textured 2D quad. Push constants pass rect_ndc + uv_rect + tint.

layout(push_constant) uniform PC {
    vec4 rect_ndc;   // (x0,y0,x1,y1) clip-space corners
    vec4 uv_rect;    // (s1,t1,s2,t2)
    vec4 tint;       // rgba multiplier
} pc;

layout(location = 0) out vec2 vUV;
layout(location = 1) out vec4 vTint;

void main() {
    vec2 corners[6] = vec2[](
        vec2(pc.rect_ndc.x, pc.rect_ndc.y),
        vec2(pc.rect_ndc.x, pc.rect_ndc.w),
        vec2(pc.rect_ndc.z, pc.rect_ndc.w),
        vec2(pc.rect_ndc.x, pc.rect_ndc.y),
        vec2(pc.rect_ndc.z, pc.rect_ndc.w),
        vec2(pc.rect_ndc.z, pc.rect_ndc.y)
    );
    vec2 uvs[6] = vec2[](
        vec2(pc.uv_rect.x, pc.uv_rect.y),
        vec2(pc.uv_rect.x, pc.uv_rect.w),
        vec2(pc.uv_rect.z, pc.uv_rect.w),
        vec2(pc.uv_rect.x, pc.uv_rect.y),
        vec2(pc.uv_rect.z, pc.uv_rect.w),
        vec2(pc.uv_rect.z, pc.uv_rect.y)
    );
    gl_Position = vec4(corners[gl_VertexIndex], 0.0, 1.0);
    vUV   = uvs[gl_VertexIndex];
    vTint = pc.tint;
}
