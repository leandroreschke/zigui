#include <metal_stdlib>
using namespace metal;

struct Point { float x; float y; };
struct Size { float width; float height; };
struct Rect { Point origin; Size size; };
struct Insets { float top; float right; float bottom; float left; };
struct Color { float r; float g; float b; float a; };
struct Radii { float top_left; float top_right; float bottom_right; float bottom_left; };
struct Affine { float m11; float m12; float m21; float m22; float tx; float ty; };
struct Quad { Rect bounds; Color background; Color border_color; Insets border_widths; Radii radii; };
struct Shadow { Rect bounds; Color color; Radii radii; Point offset; float blur_radius; float spread; };
struct Underline { Rect bounds; Color color; float thickness; float wave_amplitude; float wave_period; float reserved; };
struct Sprite { Rect bounds; Rect uv_bounds; Color color; ulong texture; uint tile_generation; uint format; };
struct ExternalSurface { Rect bounds; Rect uv_bounds; ulong surface; uint generation; uint color_space; float opacity; float reserved; };
struct Material { uint kind; uint stop_start; uint stop_count; uint reserved; Color color; Point start; Point end; Affine gradient_transform; };
struct GradientStop { float offset; float reserved0; float reserved1; float reserved2; Color color; };
struct ResolvedClip { Rect bounds; Radii radii; uint parent; uint reserved0; uint reserved1; uint reserved2; Affine inverse_transform; };
struct Globals {
    float2 viewport;
    float2 viewport_origin;
    Affine transform;
    uint material_index;
    uint clip_index;
    float opacity;
    uint blend_mode;
    uint pad0;
    uint pad1;
};
struct PathVertex { Point position; Color color; };
struct Composite { Rect bounds; float opacity; float reserved0; float reserved1; float reserved2; };
struct BackdropComposite { Rect bounds; Radii radii; Point capture_origin; Size capture_size; float blur_radius; float saturation; float opacity; };

struct VertexOut {
    float4 position [[position]];
    float2 world;
    float2 transformed;
    float2 local;
    uint instance [[flat]];
};

struct PathOut {
    float4 position [[position]];
    float2 world;
    float2 transformed;
    float4 color;
};

float2 transform_point(Affine t, float2 p) {
    return float2(p.x * t.m11 + p.y * t.m21 + t.tx, p.x * t.m12 + p.y * t.m22 + t.ty);
}

float4 clip_position(float2 point, float2 viewport, float2 viewport_origin) {
    float2 local = point - viewport_origin;
    return float4(local.x / viewport.x * 2.0 - 1.0, 1.0 - local.y / viewport.y * 2.0, 0.0, 1.0);
}

float2 corner(uint vertex_id) {
    // Triangle-strip order: top-left, top-right, bottom-left, bottom-right.
    return float2((vertex_id == 1 || vertex_id == 3) ? 1.0 : 0.0, vertex_id >= 2 ? 1.0 : 0.0);
}

vertex VertexOut quad_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]],
    const device Quad *items [[buffer(0)]], constant Globals &globals [[buffer(10)]]) {
    Quad item = items[instance_id];
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    VertexOut out;
    out.world = world;
    out.local = local;
    out.transformed = transform_point(globals.transform, world);
    out.position = clip_position(out.transformed, globals.viewport, globals.viewport_origin);
    out.instance = instance_id;
    return out;
}

float rounded_distance(float2 point, Rect bounds, Radii radii) {
    float2 center = float2(bounds.origin.x + bounds.size.width * 0.5, bounds.origin.y + bounds.size.height * 0.5);
    bool left = point.x < center.x;
    bool top = point.y < center.y;
    float radius = top ? (left ? radii.top_left : radii.top_right) : (left ? radii.bottom_left : radii.bottom_right);
    radius = clamp(radius, 0.0, min(bounds.size.width, bounds.size.height) * 0.5);
    float2 half_size = float2(bounds.size.width, bounds.size.height) * 0.5;
    float2 q = abs(point - center) - half_size + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float rounded_mask(float2 point, Rect bounds, Radii radii) {
    return 1.0 - smoothstep(-0.75, 0.75, rounded_distance(point, bounds, radii));
}

float clip_mask(float2 transformed, uint index, const device ResolvedClip *clips) {
    float result = 1.0;
    for (uint depth = 0; index != 0xffffffff && depth < 64; ++depth) {
        ResolvedClip clip = clips[index];
        float2 local = transform_point(clip.inverse_transform, transformed);
        result *= rounded_mask(local, clip.bounds, clip.radii);
        index = clip.parent;
    }
    return result;
}

float2 radial_parameter(float2 point, float2 c0, float r0, float2 c1, float r1) {
    float2 centers = c1 - c0;
    float2 relative = point - c0;
    float radius_delta = r1 - r0;
    float a = dot(centers, centers) - radius_delta * radius_delta;
    float b = -2.0 * (dot(relative, centers) + r0 * radius_delta);
    float c = dot(relative, relative) - r0 * r0;
    if (abs(a) <= 0.000001) {
        if (abs(b) <= 0.000001) return float2(0.0, 0.0);
        float value = -c / b;
        return float2(value, r0 + radius_delta * value > 0.0 ? 1.0 : 0.0);
    }
    float discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0.0) return float2(0.0, 0.0);
    float root = sqrt(max(0.0, discriminant));
    float first = (-b - root) / (2.0 * a);
    float second = (-b + root) / (2.0 * a);
    bool first_valid = r0 + radius_delta * first > 0.0;
    bool second_valid = r0 + radius_delta * second > 0.0;
    if (second_valid && (!first_valid || second > first)) return float2(second, 1.0);
    return first_valid ? float2(first, 1.0) : float2(0.0, 0.0);
}

float4 material_color(float2 point, uint index, const device Material *materials, const device GradientStop *stops, Color fallback) {
    if (index == 0xffffffff) return float4(fallback.r, fallback.g, fallback.b, fallback.a);
    Material material = materials[index];
    if (material.kind == 1) return float4(material.color.r, material.color.g, material.color.b, material.color.a);
    if ((material.kind != 2 && material.kind != 3) || material.stop_count == 0) return float4(fallback.r, fallback.g, fallback.b, fallback.a);
    float t;
    if (material.kind == 2) {
        float2 start = float2(material.start.x, material.start.y);
        float2 delta = float2(material.end.x, material.end.y) - start;
        t = clamp(dot(point - start, delta) / max(dot(delta, delta), 0.00001), 0.0, 1.0);
    } else {
        float2 local = transform_point(material.gradient_transform, point);
        float2 radial = radial_parameter(local, float2(material.start.x, material.start.y), material.color.r,
            float2(material.end.x, material.end.y), material.color.g);
        if (radial.y == 0.0) return float4(0.0);
        t = clamp(radial.x, 0.0, 1.0);
    }
    GradientStop previous = stops[material.stop_start];
    for (uint i = 1; i < material.stop_count; ++i) {
        GradientStop next = stops[material.stop_start + i];
        if (t <= next.offset) {
            float amount = clamp((t - previous.offset) / max(next.offset - previous.offset, 0.00001), 0.0, 1.0);
            float4 a = float4(previous.color.r, previous.color.g, previous.color.b, previous.color.a);
            float4 b = float4(next.color.r, next.color.g, next.color.b, next.color.a);
            return mix(a, b, amount);
        }
        previous = next;
    }
    return float4(previous.color.r, previous.color.g, previous.color.b, previous.color.a);
}

fragment float4 quad_fragment(VertexOut in [[stage_in]], const device Quad *items [[buffer(0)]],
    const device Material *materials [[buffer(1)]], const device GradientStop *stops [[buffer(2)]],
    const device ResolvedClip *clips [[buffer(3)]],
    constant Globals &globals [[buffer(10)]]) {
    Quad item = items[in.instance];
    float outer_mask = rounded_mask(in.world, item.bounds, item.radii);
    float4 fill = material_color(in.world, globals.material_index, materials, stops, item.background);
    bool has_border = item.border_widths.top > 0.0 || item.border_widths.right > 0.0 ||
        item.border_widths.bottom > 0.0 || item.border_widths.left > 0.0;
    float4 result;
    if (!has_border) {
        result = float4(fill.rgb * fill.a * outer_mask, fill.a * outer_mask);
    } else {
        Rect inner = {
            { item.bounds.origin.x + item.border_widths.left, item.bounds.origin.y + item.border_widths.top },
            { max(0.0, item.bounds.size.width - item.border_widths.left - item.border_widths.right),
              max(0.0, item.bounds.size.height - item.border_widths.top - item.border_widths.bottom) }
        };
        Radii inner_radii = {
            max(0.0, item.radii.top_left - max(item.border_widths.left, item.border_widths.top)),
            max(0.0, item.radii.top_right - max(item.border_widths.right, item.border_widths.top)),
            max(0.0, item.radii.bottom_right - max(item.border_widths.right, item.border_widths.bottom)),
            max(0.0, item.radii.bottom_left - max(item.border_widths.left, item.border_widths.bottom))
        };
        float inner_mask = inner.size.width > 0.0 && inner.size.height > 0.0 ? rounded_mask(in.world, inner, inner_radii) : 0.0;
        float border_alpha = item.border_color.a * outer_mask;
        float fill_alpha = fill.a * inner_mask;
        result.a = fill_alpha + border_alpha * (1.0 - fill_alpha);
        result.rgb = fill.rgb * fill_alpha + float3(item.border_color.r, item.border_color.g, item.border_color.b) * border_alpha * (1.0 - fill_alpha);
    }
    float coverage = clip_mask(in.transformed, globals.clip_index, clips) * globals.opacity;
    return float4(result.rgb * coverage, result.a * coverage);
}

vertex VertexOut shadow_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]],
    const device Shadow *items [[buffer(0)]], constant Globals &globals [[buffer(10)]]) {
    Shadow item = items[instance_id];
    float extent = max(0.0, item.spread + item.blur_radius * 2.0);
    Rect bounds = { { item.bounds.origin.x + item.offset.x - extent, item.bounds.origin.y + item.offset.y - extent },
                    { item.bounds.size.width + extent * 2.0, item.bounds.size.height + extent * 2.0 } };
    float2 local = corner(vertex_id);
    float2 world = float2(bounds.origin.x, bounds.origin.y) + local * float2(bounds.size.width, bounds.size.height);
    float2 transformed = transform_point(globals.transform, world);
    VertexOut out = { clip_position(transformed, globals.viewport, globals.viewport_origin), world, transformed, local, instance_id };
    return out;
}

fragment float4 shadow_fragment(VertexOut in [[stage_in]], const device Shadow *items [[buffer(0)]],
    const device ResolvedClip *clips [[buffer(3)]],
    constant Globals &globals [[buffer(10)]]) {
    Shadow item = items[in.instance];
    Rect bounds = item.bounds;
    bounds.origin.x += item.offset.x - item.spread;
    bounds.origin.y += item.offset.y - item.spread;
    bounds.size.width = max(0.0, bounds.size.width + item.spread * 2.0);
    bounds.size.height = max(0.0, bounds.size.height + item.spread * 2.0);
    if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) return float4(0.0);
    Radii radii = {
        max(0.0, item.radii.top_left + item.spread),
        max(0.0, item.radii.top_right + item.spread),
        max(0.0, item.radii.bottom_right + item.spread),
        max(0.0, item.radii.bottom_left + item.spread)
    };
    float distance = rounded_distance(in.world, bounds, radii);
    float sigma = max(item.blur_radius * 0.5, 0.5);
    float outside = max(distance, 0.0);
    float coverage = item.blur_radius <= 0.001
        ? (1.0 - smoothstep(-0.75, 0.75, distance))
        : exp(-0.5 * outside * outside / (sigma * sigma));
    float alpha = item.color.a * coverage * clip_mask(in.transformed, globals.clip_index, clips) * globals.opacity;
    return float4(item.color.r * alpha, item.color.g * alpha, item.color.b * alpha, alpha);
}

vertex VertexOut sprite_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]],
    const device Sprite *items [[buffer(0)]], constant Globals &globals [[buffer(10)]]) {
    Sprite item = items[instance_id];
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    float2 transformed = transform_point(globals.transform, world);
    VertexOut out = { clip_position(transformed, globals.viewport, globals.viewport_origin), world, transformed, local, instance_id };
    return out;
}

fragment float4 mono_sprite_fragment(VertexOut in [[stage_in]], const device Sprite *items [[buffer(0)]], texture2d<float> texture [[texture(0)]],
    const device ResolvedClip *clips [[buffer(3)]],
    constant Globals &globals [[buffer(10)]]) {
    constexpr sampler sample_filter(coord::normalized, address::clamp_to_edge, filter::linear);
    Sprite item = items[in.instance];
    float2 uv = float2(item.uv_bounds.origin.x, item.uv_bounds.origin.y) + in.local * float2(item.uv_bounds.size.width, item.uv_bounds.size.height);
    float alpha = texture.sample(sample_filter, uv).r * item.color.a * clip_mask(in.transformed, globals.clip_index, clips) * globals.opacity;
    return float4(item.color.r * alpha, item.color.g * alpha, item.color.b * alpha, alpha);
}

fragment float4 color_sprite_fragment(VertexOut in [[stage_in]], const device Sprite *items [[buffer(0)]], texture2d<float> texture [[texture(0)]],
    const device ResolvedClip *clips [[buffer(3)]],
    constant Globals &globals [[buffer(10)]]) {
    constexpr sampler sample_filter(coord::normalized, address::clamp_to_edge, filter::linear);
    Sprite item = items[in.instance];
    float2 uv = float2(item.uv_bounds.origin.x, item.uv_bounds.origin.y) + in.local * float2(item.uv_bounds.size.width, item.uv_bounds.size.height);
    float4 sampled = texture.sample(sample_filter, uv);
    sampled.rgb *= float3(item.color.r, item.color.g, item.color.b);
    sampled.a *= item.color.a * globals.opacity * clip_mask(in.transformed, globals.clip_index, clips);
    sampled.rgb *= sampled.a;
    return sampled;
}

vertex VertexOut external_surface_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]],
    const device ExternalSurface *items [[buffer(0)]], constant Globals &globals [[buffer(10)]]) {
    ExternalSurface item = items[instance_id];
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    float2 transformed = transform_point(globals.transform, world);
    VertexOut out = { clip_position(transformed, globals.viewport, globals.viewport_origin), world, transformed, local, instance_id };
    return out;
}

fragment float4 external_surface_fragment(VertexOut in [[stage_in]], const device ExternalSurface *items [[buffer(0)]],
    texture2d<float> texture [[texture(0)]], const device ResolvedClip *clips [[buffer(3)]],
    constant Globals &globals [[buffer(10)]]) {
    constexpr sampler sample_filter(coord::normalized, address::clamp_to_edge, filter::linear);
    ExternalSurface item = items[in.instance];
    float2 uv = float2(item.uv_bounds.origin.x, item.uv_bounds.origin.y) + in.local * float2(item.uv_bounds.size.width, item.uv_bounds.size.height);
    float4 sampled = texture.sample(sample_filter, uv);
    if (item.color_space == 2) {
        const float3x3 p3_to_srgb = float3x3(
            float3(1.224745, -0.042058, -0.019642),
            float3(-0.224904, 1.042081, -0.078655),
            float3(0.0, 0.0, 1.098537));
        sampled.rgb = max(p3_to_srgb * sampled.rgb, 0.0);
    } else if (item.color_space == 4) {
        float3 powered = pow(max(sampled.rgb, 0.0), float3(1.0 / 78.84375));
        float3 numerator = max(powered - 0.8359375, 0.0);
        float3 denominator = max(18.8515625 - 18.6875 * powered, 0.00001);
        float3 nits = 10000.0 * pow(numerator / denominator, float3(1.0 / 0.1593017578));
        sampled.rgb = nits / (nits + 203.0);
    } else if (item.color_space == 5) {
        float3 low = sampled.rgb * sampled.rgb / 3.0;
        float3 high = (exp((sampled.rgb - 0.55991073) / 0.17883277) + 0.28466892) / 12.0;
        sampled.rgb = mix(low, high, step(float3(0.5), sampled.rgb));
        sampled.rgb = sampled.rgb / (sampled.rgb + 1.0);
    }
    sampled.a *= item.opacity * globals.opacity * clip_mask(in.transformed, globals.clip_index, clips);
    sampled.rgb *= sampled.a;
    return sampled;
}

vertex VertexOut underline_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]],
    const device Underline *items [[buffer(0)]], constant Globals &globals [[buffer(10)]]) {
    Underline item = items[instance_id];
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    float2 transformed = transform_point(globals.transform, world);
    VertexOut out = { clip_position(transformed, globals.viewport, globals.viewport_origin), world, transformed, local, instance_id };
    return out;
}

fragment float4 underline_fragment(VertexOut in [[stage_in]], const device Underline *items [[buffer(0)]],
    const device ResolvedClip *clips [[buffer(3)]],
    constant Globals &globals [[buffer(10)]]) {
    Underline item = items[in.instance];
    float center = item.bounds.origin.y + item.bounds.size.height * 0.5;
    if (item.wave_period > 0.0 && item.wave_amplitude != 0.0)
        center += sin((in.world.x - item.bounds.origin.x) * 6.28318530718 / item.wave_period) * item.wave_amplitude;
    float coverage = 1.0 - smoothstep(item.thickness * 0.5 - 0.5, item.thickness * 0.5 + 0.5, abs(in.world.y - center));
    float alpha = item.color.a * coverage * clip_mask(in.transformed, globals.clip_index, clips) * globals.opacity;
    return float4(item.color.r * alpha, item.color.g * alpha, item.color.b * alpha, alpha);
}

vertex PathOut path_vertex(uint vertex_id [[vertex_id]], const device PathVertex *vertices [[buffer(0)]],
    constant Globals &globals [[buffer(10)]]) {
    PathVertex item = vertices[vertex_id];
    float2 world = float2(item.position.x, item.position.y);
    PathOut out;
    out.world = world;
    out.transformed = transform_point(globals.transform, world);
    out.position = clip_position(out.transformed, globals.viewport, globals.viewport_origin);
    out.color = float4(item.color.r, item.color.g, item.color.b, item.color.a);
    return out;
}

fragment float4 path_fragment(PathOut in [[stage_in]], const device Material *materials [[buffer(1)]],
    const device GradientStop *stops [[buffer(2)]], const device ResolvedClip *clips [[buffer(3)]],
    constant Globals &globals [[buffer(10)]]) {
    Color fallback = { in.color.r, in.color.g, in.color.b, in.color.a };
    float4 result = material_color(in.world, globals.material_index, materials, stops, fallback);
    result.a *= clip_mask(in.transformed, globals.clip_index, clips) * globals.opacity;
    result.rgb *= result.a;
    return result;
}

vertex VertexOut backdrop_vertex(uint vertex_id [[vertex_id]], constant BackdropComposite &item [[buffer(0)]],
    constant Globals &globals [[buffer(10)]]) {
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    VertexOut out;
    out.world = world;
    out.local = local;
    out.transformed = transform_point(globals.transform, world);
    out.position = clip_position(out.transformed, globals.viewport, globals.viewport_origin);
    out.instance = 0;
    return out;
}

float4 backdrop_blur(texture2d<float> texture, sampler sample_filter, float2 uv, float blur_radius) {
    if (blur_radius <= 0.001) return texture.sample(sample_filter, uv);
    float2 texel = 1.0 / float2(texture.get_width(), texture.get_height());
    float2 near_offset = texel * max(blur_radius * 0.5, 1.0);
    float2 far_offset = texel * max(blur_radius, 1.0);
    float2 diagonal_offset = texel * max(blur_radius * 0.7071, 1.0);
    float4 result = texture.sample(sample_filter, uv) * 0.3125;
    result += texture.sample(sample_filter, uv + float2(-near_offset.x, 0.0)) * 0.125;
    result += texture.sample(sample_filter, uv + float2(near_offset.x, 0.0)) * 0.125;
    result += texture.sample(sample_filter, uv + float2(0.0, -near_offset.y)) * 0.125;
    result += texture.sample(sample_filter, uv + float2(0.0, near_offset.y)) * 0.125;
    result += texture.sample(sample_filter, uv + float2(-far_offset.x, 0.0)) * 0.03125;
    result += texture.sample(sample_filter, uv + float2(far_offset.x, 0.0)) * 0.03125;
    result += texture.sample(sample_filter, uv + float2(0.0, -far_offset.y)) * 0.03125;
    result += texture.sample(sample_filter, uv + float2(0.0, far_offset.y)) * 0.03125;
    result += texture.sample(sample_filter, uv + float2(-diagonal_offset.x, -diagonal_offset.y)) * 0.015625;
    result += texture.sample(sample_filter, uv + float2(diagonal_offset.x, -diagonal_offset.y)) * 0.015625;
    result += texture.sample(sample_filter, uv + float2(-diagonal_offset.x, diagonal_offset.y)) * 0.015625;
    result += texture.sample(sample_filter, uv + float2(diagonal_offset.x, diagonal_offset.y)) * 0.015625;
    return result;
}

fragment float4 backdrop_fragment(VertexOut in [[stage_in]], constant BackdropComposite &item [[buffer(0)]],
    const device ResolvedClip *clips [[buffer(3)]], constant Globals &globals [[buffer(10)]],
    texture2d<float> backdrop_texture [[texture(0)]]) {
    constexpr sampler sample_filter(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 capture_origin = float2(item.capture_origin.x, item.capture_origin.y);
    float2 capture_size = float2(item.capture_size.width, item.capture_size.height);
    float2 uv = (in.transformed - capture_origin) / capture_size;
    float4 original = backdrop_texture.sample(sample_filter, uv);
    float4 blurred = backdrop_blur(backdrop_texture, sample_filter, uv, item.blur_radius);
    float3 color = blurred.a > 0.000001 ? blurred.rgb / blurred.a : 0.0;
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = luminance + (color - luminance) * item.saturation;
    float4 filtered = float4(color * blurred.a, blurred.a);
    float coverage = rounded_mask(in.world, item.bounds, item.radii) * clip_mask(in.transformed, globals.clip_index, clips) * item.opacity;
    return mix(original, filtered, clamp(coverage, 0.0, 1.0));
}

vertex VertexOut composite_vertex(uint vertex_id [[vertex_id]], constant Composite &item [[buffer(0)]],
    constant Globals &globals [[buffer(10)]]) {
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    VertexOut out;
    out.world = world;
    out.local = local;
    out.transformed = world;
    out.position = clip_position(world, globals.viewport, globals.viewport_origin);
    out.instance = 0;
    return out;
}

fragment float4 composite_fragment(VertexOut in [[stage_in]], constant Composite &item [[buffer(0)]],
    constant Globals &globals [[buffer(10)]], texture2d<float> texture [[texture(0)]],
    texture2d<float> backdrop_texture [[texture(1)]]) {
    constexpr sampler sample_filter(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 source = texture.sample(sample_filter, in.local) * item.opacity;
    float4 backdrop = backdrop_texture.sample(sample_filter, in.local);
    if (globals.blend_mode == 4)
        return min(source + backdrop, 1.0);

    float source_alpha = source.a;
    float backdrop_alpha = backdrop.a;
    float3 source_color = source_alpha > 0.000001 ? source.rgb / source_alpha : 0.0;
    float3 backdrop_color = backdrop_alpha > 0.000001 ? backdrop.rgb / backdrop_alpha : 0.0;
    float3 blended = source_color;
    if (globals.blend_mode == 1)
        blended = source_color * backdrop_color;
    else if (globals.blend_mode == 2)
        blended = source_color + backdrop_color - source_color * backdrop_color;
    else if (globals.blend_mode == 3)
        blended = mix(
            2.0 * source_color * backdrop_color,
            1.0 - 2.0 * (1.0 - source_color) * (1.0 - backdrop_color),
            step(float3(0.5), backdrop_color));

    float4 result;
    result.rgb = (1.0 - backdrop_alpha) * source.rgb +
        (1.0 - source_alpha) * backdrop.rgb +
        source_alpha * backdrop_alpha * blended;
    result.a = source_alpha + backdrop_alpha - source_alpha * backdrop_alpha;
    return clamp(result, 0.0, 1.0);
}

struct PresentOut {
    float4 position [[position]];
    float2 local;
};

vertex PresentOut present_vertex(uint vertex_id [[vertex_id]]) {
    float2 local = corner(vertex_id);
    PresentOut out;
    out.position = float4(local.x * 2.0 - 1.0, 1.0 - local.y * 2.0, 0.0, 1.0);
    out.local = local;
    return out;
}

fragment float4 present_fragment(PresentOut in [[stage_in]], texture2d<float> texture [[texture(0)]]) {
    constexpr sampler sample_filter(coord::normalized, address::clamp_to_edge, filter::nearest);
    return texture.sample(sample_filter, in.local);
}
