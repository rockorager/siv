// One quad per instance (or the push-constant region), as a 4-vertex
// triangle strip, in device pixels mapped to the target. Instances with a
// hole are drawn four times each (pc.pieces): the four quads around it
// (above, below, left, right; empty ones rasterize nothing).

layout(location = 0) flat out uint v_inst;

void main() {
    ivec4 q;
    uint inst = uint(gl_InstanceIndex);
    if (pc.region.z > pc.region.x) {
        q = pc.region;
    } else if (pc.pieces == 0u) {
        q = insts[inst].quad;
    } else {
        inst >>= 2u;
        uint piece = uint(gl_InstanceIndex) & 3u;
        q = insts[inst].quad;
        ivec4 h = insts[inst].hole;
        if (h.z > h.x && h.w > h.y) {
            if (piece == 0u) q.w = h.y;
            else if (piece == 1u) q.y = h.w;
            else if (piece == 2u) q = ivec4(q.x, h.y, h.x, h.w);
            else q = ivec4(h.z, h.y, q.z, h.w);
        } else if (piece != 0u) {
            q = ivec4(0);
        }
    }
    vec2 p = vec2((gl_VertexIndex & 1) != 0 ? q.z : q.x, (gl_VertexIndex & 2) != 0 ? q.w : q.y);
    gl_Position = vec4((p - pc.origin) / pc.size * 2.0 - 1.0, 0.0, 1.0);
    v_inst = inst;
}
