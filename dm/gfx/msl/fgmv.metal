// Frame generation's motion (nvn_mtl.m fg_motion): the motion between two presented pictures, estimated here because the game gives none, as the MetalFX frame interpolator's
// motion texture. MetalFX's own flow finds motion up to about 64 px a frame at 1176x540 (and tears or gives up past 96-192 px: the picture stays on one of the two frames, a
// judder on fast camera turns); with motion vectors it places any pan exactly. Three passes at 1/8 of the picture's size, and one over their tiles:
//   fgmv_luma    each 8x8 block's mean luma (one per present, kept with its ring slot for the next present's search)
//   fgmv_search  each tile of 8x8 of those (64x64 px of the picture) searched against the previous present's luma within +-FGMV_R (+-192 px), with a sub-pixel fit
//   fgmv_pick    each 1/8 pixel takes, of its tile's vector, its 8 neighbours' and no motion, the one that matches best around it, so a still HUD or a character the camera
//                follows keeps no motion beside the panning background
//   fgmv_cut     whether the two pictures are a cut: the tiles' own confidence, low everywhere (nothing in either picture is where the search found it)
// The motion texture is at 1/8 size, its vectors in its own pixels pointing to where a pixel was in the previous picture (MetalFX's convention, scale 1). What follows
// works at the picture's own size: the still blocks (fgmv_still), how badly the motion explains each 1/8 pixel (fgmv_conf), and which blocks of the generated frame are
// the present's own pixels (fgmv_hud, fgmv_keep).
#include <metal_stdlib>
using namespace metal;

#define FGMV_T 8                       // tile size in 1/8 pixels
#define FGMV_R 24                      // search radius in 1/8 pixels
#define FGMV_P (FGMV_T + 2 * FGMV_R)   // the previous picture's window a tile searches
#define FGMV_N ((2 * FGMV_R + 1) * (2 * FGMV_R + 1))
#define FGMV_TG 256
#ifndef FGMV_REFINE
#define FGMV_REFINE 1   // fgmv_pick refines the vector it picked (half then quarter 1/8 pixel steps)
#endif

kernel void fgmv_luma(texture2d<float, access::read> src [[texture(0)]], texture2d<half, access::write> dst [[texture(1)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
    uint2 mx = uint2(src.get_width() - 1, src.get_height() - 1), o = g * 8;
    float s = 0;
    for (uint y = 0; y < 8; y += 2) for (uint x = 0; x < 8; x += 2) {   // 16 of the 64: the mean of a block whose detail the search does not need
        float3 c = src.read(min(o + uint2(x, y), mx)).rgb;
        s += dot(c, float3(0.299, 0.587, 0.114));
    }
    dst.write(half4(half(s / 16)), g);
}

// tiles: xy the vector (1/8 pixels, pointing to the previous picture), z how far its match beats the tile's mean (0 = a flat tile, nothing to go by), w that mean
// difference (0 = nothing in the tile to match: a flat sky, a black screen)
kernel void fgmv_search(texture2d<half, access::read> cur [[texture(0)]], texture2d<half, access::read> prev [[texture(1)]], texture2d<half, access::write> tiles [[texture(2)]],
                        uint2 tg [[threadgroup_position_in_grid]], uint li [[thread_index_in_threadgroup]]) {
    threadgroup half c[FGMV_T * FGMV_T];
    threadgroup half p[FGMV_P * FGMV_P];
    threadgroup float bc[FGMV_TG], bs[FGMV_TG], sm[FGMV_TG];
    threadgroup int bk[FGMV_TG];
    int2 mx = int2(cur.get_width() - 1, cur.get_height() - 1), t0 = int2(tg) * FGMV_T;
    for (uint i = li; i < FGMV_T * FGMV_T; i += FGMV_TG) c[i] = cur.read(uint2(clamp(t0 + int2(i % FGMV_T, i / FGMV_T), int2(0), mx))).r;
    for (uint i = li; i < FGMV_P * FGMV_P; i += FGMV_TG) p[i] = prev.read(uint2(clamp(t0 - FGMV_R + int2(i % FGMV_P, i / FGMV_P), int2(0), mx))).r;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float best = INFINITY, bsad = 0, sum = 0; int bkk = FGMV_N / 2;
    for (int k = (int)li; k < FGMV_N; k += FGMV_TG) {
        int ox = k % (2 * FGMV_R + 1), oy = k / (2 * FGMV_R + 1);   // window offsets (FGMV_R, FGMV_R = no motion)
        float sad = 0;
        for (int y = 0; y < FGMV_T; y++) for (int x = 0; x < FGMV_T; x++) sad += fabs(float(c[y * FGMV_T + x]) - float(p[(y + oy) * FGMV_P + x + ox]));
        sad *= 1.0f / (FGMV_T * FGMV_T);
        float cost = sad + 0.0004f * float(abs(ox - FGMV_R) + abs(oy - FGMV_R));   // ties (repeated patterns, flat areas) go to the smaller motion
        sum += sad;
        if (cost < best) { best = cost; bsad = sad; bkk = k; }
    }
    bc[li] = best; bs[li] = bsad; bk[li] = bkk; sm[li] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = FGMV_TG / 2; s > 0; s >>= 1) {
        if (li < s) {
            if (bc[li + s] < bc[li] || (bc[li + s] == bc[li] && bk[li + s] < bk[li])) { bc[li] = bc[li + s]; bs[li] = bs[li + s]; bk[li] = bk[li + s]; }
            sm[li] += sm[li + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (li) return;
    int ox = bk[0] % (2 * FGMV_R + 1), oy = bk[0] / (2 * FGMV_R + 1);
    float2 v = float2(ox - FGMV_R, oy - FGMV_R);
    // sub-pixel: a parabola through the costs beside the best one
    if (ox > 0 && ox < 2 * FGMV_R && oy > 0 && oy < 2 * FGMV_R) {
        float s0 = bs[0], sx[2], sy[2];
        for (int d = 0; d < 2; d++) {
            int dd = d ? 1 : -1; float a = 0, b = 0;
            for (int y = 0; y < FGMV_T; y++) for (int x = 0; x < FGMV_T; x++) {
                float cv = float(c[y * FGMV_T + x]);
                a += fabs(cv - float(p[(y + oy) * FGMV_P + x + ox + dd])); b += fabs(cv - float(p[(y + oy + dd) * FGMV_P + x + ox]));
            }
            sx[d] = a * (1.0f / (FGMV_T * FGMV_T)); sy[d] = b * (1.0f / (FGMV_T * FGMV_T));
        }
        float qx = sx[0] - 2 * s0 + sx[1], qy = sy[0] - 2 * s0 + sy[1];
        if (qx > 1e-5f) v.x += clamp(0.5f * (sx[0] - sx[1]) / qx, -0.5f, 0.5f);
        if (qy > 1e-5f) v.y += clamp(0.5f * (sy[0] - sy[1]) / qy, -0.5f, 0.5f);
    }
    float mean = sm[0] / FGMV_N, conf = mean > 1e-3f ? clamp((mean - bs[0]) / mean, 0.0f, 1.0f) : 0.0f;
    tiles.write(half4(half(v.x), half(v.y), half(conf), half(mean)), tg);
}

// The 3x3 window's mean absolute difference between cur at g and prev at g + v (bilinear, in 1/8 pixels)
static float fgmv_cost(texture2d<half, access::read> cur, texture2d<half, access::sample> prev, int2 g, float2 v, float2 inv, int2 mx) {
    constexpr sampler ls(coord::normalized, address::clamp_to_edge, filter::linear);
    float s = 0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        int2 q = clamp(g + int2(x, y), int2(0), mx);
        s += fabs(float(cur.read(uint2(q)).r) - float(prev.sample(ls, (float2(q) + 0.5f + v) * inv).r));
    }
    return s * (1.0f / 9);
}
kernel void fgmv_pick(texture2d<half, access::read> cur [[texture(0)]], texture2d<half, access::sample> prev [[texture(1)]], texture2d<half, access::read> tiles [[texture(2)]],
                      texture2d<half, access::write> mot [[texture(3)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= mot.get_width() || g.y >= mot.get_height()) return;
    int2 mx = int2(cur.get_width() - 1, cur.get_height() - 1), tm = int2(tiles.get_width() - 1, tiles.get_height() - 1), t = int2(g) / FGMV_T, gi = int2(g);
    float2 inv = 1.0f / float2(prev.get_width(), prev.get_height());
    float2 bv = 0; float bc = fgmv_cost(cur, prev, gi, 0, inv, mx) - 0.004f;   // no motion wins ties: a still HUD and flat areas stay put
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        half4 tv = tiles.read(uint2(clamp(t + int2(x, y), int2(0), tm)));
        if (tv.z < 0.05h) continue;   // a flat tile's vector says nothing
        float2 v = float2(tv.xy); float cst = fgmv_cost(cur, prev, gi, v, inv, mx) - (x == 0 && y == 0 ? 0.001f : 0);
        if (cst < bc) { bc = cst; bv = v; }
    }
    // Refined around the vector picked, in half then quarter steps of a 1/8 pixel (4 then 2 px of the picture): a tile's one vector is off within its 64x64 px wherever the
    // motion varies across it (a camera turn moves near ground faster than far), and what it left unexplained was pasted from the present or smeared (FGMV_REFINE)
    if (FGMV_REFINE && any(bv != 0))
        for (float st = 0.5f; st > 0.2f; st *= 0.5f) {
            float2 c = bv;
            for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
                if (!x && !y) continue;
                float2 v = c + float2(x, y) * st; float cst = fgmv_cost(cur, prev, gi, v, inv, mx);
                if (cst < bc) { bc = cst; bv = v; }
            }
        }
    mot.write(half4(half(bv.x), half(bv.y), 0, 0), g);
}

// fgmv_cut (nvn_mtl.m fg_keep): whether this pair of presents is a cut, so that neither real picture gives way to a picture invented between them. The tiles alone say
// it: at a cut nothing in either picture is where the search found it, so every tile with something
// to match changes at its best offset and no offset explains it (fgmv_search's confidence, low everywhere). A pan, however fast within the search's reach, explains its
// tiles, and a still picture leaves no difference at all. A fast pan past the reach explains none of them either and reads as a cut here: past 192 px a frame the
// interpolator has nothing to place the picture with (t_framegen cut).
//   flags   x 1 when the pair is a cut, y the part of the picture's tiles that changed, z their mean confidence, w 0
#define FGMV_CUT_DETAIL 0.01f   // a tile whose mean difference over the search is under this has nothing to match (a flat sky, a black screen): its confidence says nothing
#define FGMV_CUT_PIX 0.015f     // the difference a tile keeps at its best offset past which it counts as changed (about 4/255 of luma)
#define FGMV_CUT_TILES 0.25f    // the part of all the tiles that must have something to match, or the picture is too flat for the confidence to mean anything
#define FGMV_CUT_PART 0.6f      // the part of the detailed tiles that must have changed
#define FGMV_CUT_CONF 0.75f     // their mean confidence under which no motion explains the change (a pan's search explains over 0.9 of it)
kernel void fgmv_cut(texture2d<half, access::read> tiles [[texture(0)]], texture2d<half, access::write> flags [[texture(1)]],
                     constant uint &sw [[buffer(0)]], uint li [[thread_index_in_threadgroup]]) {
    threadgroup float det[FGMV_TG], chg[FGMV_TG], cf[FGMV_TG];
    uint2 n = uint2(tiles.get_width(), tiles.get_height());
    float d = 0, c = 0, s = 0;
    for (uint i = li; i < n.x * n.y; i += FGMV_TG) {
        half4 t = tiles.read(uint2(i % n.x, i / n.x));
        float mean = float(t.w), best = mean * (1 - float(t.z));
        if (mean < FGMV_CUT_DETAIL) continue;
        d++;
        if (best < FGMV_CUT_PIX) continue;
        c++; s += float(t.z);
    }
    det[li] = d; chg[li] = c; cf[li] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint st = FGMV_TG / 2; st > 0; st >>= 1) {
        if (li < st) { det[li] += det[li + st]; chg[li] += chg[li + st]; cf[li] += cf[li + st]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (li) return;
    float part = chg[0] / max(1.0f, (float)(n.x * n.y)), conf = chg[0] > 0 ? cf[0] / chg[0] : 1;
    float cut = det[0] >= FGMV_CUT_TILES * (float)(n.x * n.y) && det[0] > 0 && chg[0] / det[0] >= FGMV_CUT_PART && conf <= FGMV_CUT_CONF;
    flags.write(half4(half(cut && (sw & 1) ? 1 : 0), half(part), half(conf), 0), uint2(0));
}

// The HUD (nvn_mtl.m fg_keep): with motion anywhere in the picture MetalFX moves still pixels beside it too, so a still HUD over a panning background smears even when its
// own vectors say it stays (probe: 0.03-0.09 of mean error on the HUD, against 0.0015 with no motion at all). Pixels that did not change since the previous present and have
// detail around them (a HUD, the character the camera follows when it stands still), and still pixels near those (a HUD's flat fill), are taken from the present as it is.
// A flat still area alone is left to the interpolator: something thin that crossed it between the two presents is in the generated frame there.
//   fgmv_still  per 4x4 block of the picture: 1 still, 2 still with detail (a 6x6 window: no channel changed by more than 2/255; luma spread over 0.08)
//   fgmv_hud    per block: still, with a still detailed block within 3 blocks (12 px); a cut's present whole (fgmv_cut)
//   fgmv_keep   per pixel of the generated frame: the present's own where its block is kept
kernel void fgmv_still(texture2d<float, access::read> cur [[texture(0)]], texture2d<float, access::read> prev [[texture(1)]], texture2d<half, access::write> st [[texture(2)]],
                       uint2 g [[thread_position_in_grid]]) {
    if (g.x >= st.get_width() || g.y >= st.get_height()) return;
    int2 mx = int2(cur.get_width() - 1, cur.get_height() - 1), o = int2(g) * 4 - 1;
    float d = 0, lo = 1e9, hi = -1e9;
    for (int y = 0; y < 6; y++) for (int x = 0; x < 6; x++) {
        uint2 p = uint2(clamp(o + int2(x, y), int2(0), mx)); float3 a = cur.read(p).rgb, b = prev.read(p).rgb;
        float3 e = fabs(a - b); d = max(d, max(e.x, max(e.y, e.z)));
        float l = dot(a, float3(0.299, 0.587, 0.114)); lo = min(lo, l); hi = max(hi, l);
    }
    half v = d <= 2.5h / 255 ? (hi - lo > 0.08 ? 2.0h : 1.0h) : 0.0h;
    st.write(half4(v), g);
}
#define FGMV_FLOOR 0.03f   // a mean luma difference over 3x3 under which what the motion leaves is not looked at
#define FGMV_BAD 0.5f   // the part of the change left unexplained past which a 1/8 pixel's motion is not trusted (fgmv_conf)
// fgmv_conf: per 1/8 pixel, how badly the motion picked for it explains the change (fgmv_cost of its vector). Where no vector does (an object moving its own way,
// what it uncovers, motion past the search), MetalFX smears or tears: there fgmv_hud keeps the present's own pixels, a small area at 30 frames a second instead of a
// guessed picture (t_framegen stab: an object moving against the pan)
kernel void fgmv_conf(texture2d<half, access::read> cur [[texture(0)]], texture2d<half, access::sample> prev [[texture(1)]], texture2d<half, access::read> mot [[texture(2)]],
                      texture2d<half, access::write> conf [[texture(3)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= conf.get_width() || g.y >= conf.get_height()) return;
    int2 mx = int2(cur.get_width() - 1, cur.get_height() - 1);
    float2 inv = 1.0f / float2(prev.get_width(), prev.get_height());
    // Not trusted: the motion leaves a visible change (past FGMV_FLOOR) that is a large part of the change with no motion at all. Not an absolute cost alone: a correctly
    // tracked detailed picture costs as much as a mismatch elsewhere (at 0.045, 7-14 % of a correctly panning scene was held at 30 fps, t_framegen stab)
    float2 v = float2(mot.read(g).xy);
    float cv = fgmv_cost(cur, prev, int2(g), v, inv, mx), c0 = fgmv_cost(cur, prev, int2(g), 0, inv, mx);
    float r = cv > FGMV_FLOOR ? cv / max(c0, 1e-4f) : 0.0f;
    // Motion its neighbours share (each 2 apart within a third of its length and one 1/8 pixel: a camera turn moves near ground faster than far, and the 1/8 search's tile vectors
    // jump by a 1/8 pixel or two between tiles) is a camera turn or a body moving whole: what the vector leaves there is detail and depth the tile vectors cannot follow, and the
    // present's own pixels in its place, unmoved, were blocks half a step behind the picture around them at 30 fps, the texture artifacts of a camera turn in X13. Written negative: fgmv_keep moves the present's pixels there half the step. Motion of its own (a character moving its own way,
    // what it uncovers, the edge new picture enters by) stays positive: the present's own pixels, unmoved, as X13
    if (r > FGMV_BAD) {
        int2 cm = int2(mot.get_width() - 1, mot.get_height() - 1); int shared = 1;
        for (int y = -2; y <= 2 && shared; y += 2) for (int x = -2; x <= 2; x += 2) {
            float2 n = float2(mot.read(uint2(clamp(int2(g) + int2(x, y), int2(0), cm))).xy);
            if (length(n - v) > 1.0f + length(v) / 3) { shared = 0; break; }
        }
        if (shared) r = -r;
    }
    conf.write(half4(half(r)), g);
}
// FGMV_PASTE (DM_FRAMEGEN_PASTE=1; off by default): a block whose motion is not trusted and not shared takes the present's own pixels over the 24x24 around it. Off, the
// interpolator's frame stays there. t_framegen stab with the refined motion (fgmv_pick), pans of 24 and 96 px a frame, plain and as on a camera turn: pasted, 7-13 % of the
// scene was held at 30 fps (squares of the present's picture that stepped at 30 while the rest moved at 60: most on scenery panning correctly, the motion's mismatch alone)
// and the scene error was 0.0058-0.0237; not pasted, 0.1-0.7 % held and 0.0023-0.0187 (the picture's own error halved on a slow pan), the moving object's error
// 0.063-0.113 against 0.093-0.131, at the cost of more smear right around that object (0.045-0.077 against 0.028-0.059 of what none of the three pictures has)
constant bool FGMV_PASTE [[function_constant(0)]];
// flags: fgmv_cut's (x a cut)
kernel void fgmv_hud(texture2d<half, access::read> st [[texture(0)]], texture2d<half, access::write> keep [[texture(1)]], texture2d<half, access::read> conf [[texture(2)]],
                     texture2d<half, access::read> flags [[texture(3)]], constant uint &sw [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= keep.get_width() || g.y >= keep.get_height()) return;
    int2 mx = int2(st.get_width() - 1, st.get_height() - 1), gi = int2(g);
    // A cut (fgmv_cut, DM_FRAMEGEN_CUT): the present's own picture over the whole frame. There is no picture between two scenes, so the interpolator's blend of them
    // is what the screen shows instead of each: the display link shows this present's own picture on the tick before its own, and both real frames are seen as drawn
    half k = (sw & 1) && flags.read(uint2(0)).x > 0.5h ? 1.0h : 0.0h;
    // A block within one 1/8 pixel of motion of its own not trusted (fgmv_conf positive: a model moving its own way on a camera turn, what it uncovers): the present's own (1), over
    // the 24x24 around it as in X13, so a model is taken whole from one moment. Cut to the 1/8 pixel alone, parts of a model came from the present and the cells beside them from the
    // interpolation, and models twitched on camera turns (X14's first builds, the owner). Motion its neighbours share (negative: detail of the ground the camera turns over), in this
    // 1/8 pixel alone: the present's own moved half its step (0.5, fgmv_keep), where X13's unmoved squares were the patches of texture on a camera turn
    if (k < 1.0h && conf.get_width() > 1) {
        int2 cm = int2(conf.get_width() - 1, conf.get_height() - 1), c = gi / 2;
        if (FGMV_PASTE) for (int y = -1; y <= 1 && k < 1.0h; y++) for (int x = -1; x <= 1; x++) if (float(conf.read(uint2(clamp(c + int2(x, y), int2(0), cm))).r) > FGMV_BAD) { k = 1; break; }
        if (k < 1.0h && float(conf.read(uint2(clamp(c, int2(0), cm))).r) < -FGMV_BAD) k = 0.5h;
    }
    if (k < 1.0h && st.read(g).r > 0.5h)
        for (int y = -3; y <= 3 && k < 1.0h; y++) for (int x = -3; x <= 3; x++) if (st.read(uint2(clamp(gi + int2(x, y), int2(0), mx))).r > 1.5h) { k = 1; break; }
    keep.write(half4(k), g);
}
// fgmv_pstill: per pixel, 1 where it did not change across the last three presents (no channel by more than 2/255 from the present before, nor that one from the one
// before it). A HUD drawn over a moving picture, a half-transparent panel with text on it, has no still 4x4 block: its text moved with the picture behind it, with 10-20
// times the error of the rest (t_framegen stab: 0.031 at 24 px a frame, 0.096 at 96). Three presents, not two, so a moving picture matching by chance is rare; where it
// does, a smooth area, the present's own pixel is next to what the interpolation would give. prev2 is prev when there is no present before it
kernel void fgmv_pstill(texture2d<float, access::read> cur [[texture(0)]], texture2d<float, access::read> prev [[texture(1)]], texture2d<float, access::read> prev2 [[texture(2)]],
                        texture2d<half, access::write> m [[texture(3)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= m.get_width() || g.y >= m.get_height()) return;
    float3 a = cur.read(g).rgb, b = prev.read(g).rgb, c = prev2.read(g).rgb;
    float3 d = max(fabs(a - b), fabs(b - c));
    m.write(half4(max(d.x, max(d.y, d.z)) <= 2.5f / 255 ? 1.0h : 0.0h), g);
}
// The UI mask (nvn_mtl.m fg_ui_pass_begin / fg_ui_take): a game whose UI is the frame's own last pass draws it into the picture the present shows, opened with
// load and no depth, so the picture before that pass (copied into a host texture as it opened) and the picture presented (copied with the snapshot) differ by the
// UI alone. Those two tell the HUD from the still blocks fgmv_still/fgmv_hud guess at, and they are right exactly when the HUD changes between two presents,
// which is when a guess fails: a dialogue line or a heart is the present's own pixels in fgmv_keep, at the rate the game draws them, over a world still
// interpolated. One block per 4x4 of the generated frame; the fraction along a HUD's edge blends (fgmv_keep's two keys) instead of freezing a 4 px halo.
// A frame with no such pass runs it with one texel for both pictures and writes 0 everywhere: a mask from another frame cannot survive.
#define FGMV_UI_DIFF (2.0f / 255)   // a channel's change under which a texel did not change (fgmv_still's own is 2.5/255 of luma)
kernel void fgmv_uimask(texture2d<float, access::read> shown [[texture(0)]], texture2d<float, access::read> hudless [[texture(1)]],
                        texture2d<half, access::write> mask [[texture(2)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= mask.get_width() || g.y >= mask.get_height()) return;
    // The two pictures are the same one at two sizes: the one the screen shows (the present's copy, in the generated frame's own size) and the game's own,
    // where its UI pass drew (its internal resolution, which the dynamic resolution steps). A block is 4x4 of the generated frame; its texels are compared
    // with the same place in the game's picture, mapped by each one's own size — no shared factor, so neither 1920x1080 nor 1280x720 against 1440x810 is
    // sampled in the wrong place
    uint2 m = uint2(mask.get_width(), mask.get_height()), s = uint2(shown.get_width(), shown.get_height()), h = uint2(hudless.get_width(), hudless.get_height());
    uint2 b0 = (g * s) / m, b1 = ((g + 1) * s + m - 1) / m;   // the block's first texel and one past its last
    int w = max(1, (int)(b1.x - b0.x)), hh = max(1, (int)(b1.y - b0.y)), n = 0;
    for (int y = 0; y < hh; y++) for (int x = 0; x < w; x++) {
        uint2 ps = min(b0 + uint2(x, y), s - 1);
        uint2 ph = min((ps * h) / s, h - 1);
        float3 e = fabs(shown.read(ps).rgb - hudless.read(ph).rgb);
        if (max(e.x, max(e.y, e.z)) > FGMV_UI_DIFF) n++;
    }
    mask.write(half4(half(float(n) / float(w * hh))), g);
}
// The part of the picture the mask covers (fg_ui_take, read back with the snapshot's commit): past FG_UI_BLANK the frame is shown as drawn, as in the game's
// menus (a menu, a fade, a game that composes its UI as one full-screen quad), and the interpolation is not paid for. Not on the CPU before the frame: nothing
// of a frame's own GPU work is waited for, so the answer starts the next frame.
kernel void fgmv_uisum(texture2d<half, access::read> mask [[texture(0)]], device float *out [[buffer(0)]], uint li [[thread_index_in_threadgroup]]) {
    threadgroup float s[FGMV_TG];
    uint2 n = uint2(mask.get_width(), mask.get_height());
    float v = 0;
    for (uint i = li; i < n.x * n.y; i += FGMV_TG) v += float(mask.read(uint2(i % n.x, i / n.x)).r);
    s[li] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint st = FGMV_TG / 2; st > 0; st >>= 1) { if (li < st) s[li] += s[li + st]; threadgroup_barrier(mem_flags::mem_threadgroup); }
    if (!li) out[0] = s[0] / max(1.0f, (float)(n.x * n.y));
}
// keep 1 (a HUD, still pixels) and the three-present still mask: the present's own pixel. keep 0.5 (motion not trusted, fgmv_conf): the present's picture moved half the block's
// step back towards the previous one, where it is at the generated frame's moment: the motion v takes a pixel of the present to the previous picture (fgmv_pick), so the frame between
// shows at p what the present has at p - v/2. Shown unmoved, those blocks were half a step behind the picture around them, at 30 fps: blocks of texture that lagged on a camera turn (X13)
kernel void fgmv_keep(texture2d<float, access::sample> cur [[texture(0)]], texture2d<half, access::read> keep [[texture(1)]], texture2d<float, access::write> out [[texture(2)]],
                      texture2d<half, access::read> pm [[texture(3)]], texture2d<half, access::read> mot [[texture(4)]], texture2d<half, access::read> ui [[texture(5)]],
                      uint2 g [[thread_position_in_grid]]) {
    if (g.x >= out.get_width() || g.y >= out.get_height()) return;
    half k = max(keep.read(min(g / 4, uint2(keep.get_width() - 1, keep.get_height() - 1))).r,   // the game's own UI pass where it has one (fgmv_uimask, 0 = none)
                 ui.read(min(g / 4, uint2(ui.get_width() - 1, ui.get_height() - 1))).r);
    if (k > 0.75h || pm.read(g).r > 0.5h) { out.write(cur.read(g), g); return; }
    if (k < 0.25h) return;
    constexpr sampler ls(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 size = float2(cur.get_width(), cur.get_height()), sc = size / float2(mot.get_width(), mot.get_height());
    uint2 mp = min(uint2(float2(g) / sc), uint2(mot.get_width() - 1, mot.get_height() - 1));
    float2 v = float2(mot.read(mp).xy) * sc;   // in the picture's pixels
    out.write(cur.sample(ls, (float2(g) + 0.5f - 0.5f * v) / size), g);
}
