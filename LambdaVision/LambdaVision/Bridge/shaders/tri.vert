#version 450

layout(push_constant) uniform PC {
    float time;
} pc;

vec2 positions[3] = vec2[](
    vec2( 0.0,  0.7),
    vec2(-0.7, -0.5),
    vec2( 0.7, -0.5)
);
vec3 colors[3] = vec3[](
    vec3(1.0, 0.2, 0.2),
    vec3(0.2, 1.0, 0.2),
    vec3(0.2, 0.2, 1.0)
);

layout(location = 0) out vec3 vColor;

void main() {
    float c = cos(pc.time);
    float s = sin(pc.time);
    vec2 p = positions[gl_VertexIndex];
    vec2 r = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
    gl_Position = vec4(r, 0.0, 1.0);
    vColor = colors[gl_VertexIndex];
}
