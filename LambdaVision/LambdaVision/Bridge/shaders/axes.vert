#version 450
// 3D world-space line/triangle. Vertex attrs: vec3 pos, vec4 color.
// Push constant: mat4 mvp (clip = mvp * pos).
layout(push_constant) uniform PC { mat4 mvp; } pc;
layout(location = 0) in vec3 inPos;
layout(location = 1) in vec4 inColor;
layout(location = 0) out vec4 vColor;
void main() {
    gl_Position = pc.mvp * vec4(inPos, 1.0);
    vColor = inColor;
}
