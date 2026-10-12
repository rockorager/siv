// One quad per instance (or the push-constant region), as a 4-vertex
// triangle strip, in device pixels mapped to the target.

layout(location = 0) flat out uint v_inst;

void main() {
    ivec4 q;
    if (pc.region.z > pc.region.x) {
        q = pc.region;
    } else {
        q = insts[gl_InstanceIndex].quad;
    }
    vec2 p = vec2((gl_VertexIndex & 1) != 0 ? q.z : q.x, (gl_VertexIndex & 2) != 0 ? q.w : q.y);
    gl_Position = vec4((p - pc.origin) / pc.size * 2.0 - 1.0, 0.0, 1.0);
    v_inst = gl_InstanceIndex;
}
