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
struct Sprite { Rect bounds; Rect uv_bounds; Color color; uint2 texture_id; uint tile_generation; uint format; uint effect; float effect_radius; float effect_height; uint effect_reserved; };
struct ExternalSurface { Rect bounds; Rect uv_bounds; uint2 surface; uint generation; uint color_space; float opacity; float reserved; };
struct Material { uint kind; uint stop_start; uint stop_count; uint reserved; Color color; Point start; Point end; Affine gradient_transform; };
struct GradientStop { float offset; float3 reserved; Color color; };
struct ResolvedClip { Rect bounds; Radii radii; uint parent; uint3 reserved; Affine inverse_transform; };
struct PathVertex { Point position; Color color; };
struct Composite { Rect bounds; float opacity; float3 reserved; };

StructuredBuffer<Quad> quads : register(t0);
StructuredBuffer<Shadow> shadows : register(t1);
StructuredBuffer<Underline> underlines : register(t2);
StructuredBuffer<Sprite> sprites : register(t3);
StructuredBuffer<ExternalSurface> surfaces : register(t4);
StructuredBuffer<PathVertex> path_vertices : register(t5);
StructuredBuffer<Material> materials : register(t6);
StructuredBuffer<GradientStop> gradient_stops : register(t7);
StructuredBuffer<ResolvedClip> clips : register(t8);
Texture2D<float4> image_texture : register(t9);
Texture2D<float4> backdrop_texture : register(t10);
SamplerState image_sampler : register(s0);

cbuffer Globals : register(b10) {
    float2 viewport;
    float2 viewport_origin;
    float4 transform_x;
    float4 transform_y;
    float2 composite_origin;
    float2 composite_size;
    uint payload_start;
    uint material_index;
    uint clip_index;
    uint operation_kind;
    float opacity;
    uint blend_mode;
    uint2 globals_padding;
};

struct VertexOut {
    float4 position : SV_POSITION;
    float2 world : WORLD;
    float2 transformed : TRANSFORMED;
    float2 local : LOCAL;
    nointerpolation uint item : ITEM;
};

struct PathOut {
    float4 position : SV_POSITION;
    float2 world : WORLD;
    float2 transformed : TRANSFORMED;
    float4 color : COLOR;
};

float2 transform_point(Affine transform, float2 position) {
    return float2(
        position.x * transform.m11 + position.y * transform.m21 + transform.tx,
        position.x * transform.m12 + position.y * transform.m22 + transform.ty);
}

float2 active_transform(float2 position) {
    return float2(dot(float3(position, 1.0), transform_x.xyz), dot(float3(position, 1.0), transform_y.xyz));
}

float4 clip_position(float2 position) {
    float2 local = position - viewport_origin;
    return float4(local.x / viewport.x * 2.0 - 1.0, 1.0 - local.y / viewport.y * 2.0, 0.0, 1.0);
}

float2 corner(uint vertex_id) {
    return float2((vertex_id == 1 || vertex_id == 3) ? 1.0 : 0.0, vertex_id >= 2 ? 1.0 : 0.0);
}

float rounded_distance(float2 position, Rect bounds, Radii radii) {
    float2 center = float2(bounds.origin.x + bounds.size.width * 0.5, bounds.origin.y + bounds.size.height * 0.5);
    bool left = position.x < center.x;
    bool top = position.y < center.y;
    float radius = top ? (left ? radii.top_left : radii.top_right) : (left ? radii.bottom_left : radii.bottom_right);
    radius = clamp(radius, 0.0, min(bounds.size.width, bounds.size.height) * 0.5);
    float2 half_size = float2(bounds.size.width, bounds.size.height) * 0.5;
    float2 q = abs(position - center) - half_size + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float rounded_mask(float2 position, Rect bounds, Radii radii) {
    return 1.0 - smoothstep(-0.75, 0.75, rounded_distance(position, bounds, radii));
}

float clip_mask(float2 transformed, uint index) {
    float result = 1.0;
    [loop] for (uint depth = 0; index != 0xffffffff && depth < 64; ++depth) {
        ResolvedClip clip = clips[index];
        float2 local = transform_point(clip.inverse_transform, transformed);
        result *= rounded_mask(local, clip.bounds, clip.radii);
        index = clip.parent;
    }
    return result;
}

float2 radial_parameter(float2 position, float2 c0, float r0, float2 c1, float r1) {
    float2 centers = c1 - c0;
    float2 relative = position - c0;
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

float4 material_color(float2 position, uint index, Color fallback) {
    if (index == 0xffffffff) return float4(fallback.r, fallback.g, fallback.b, fallback.a);
    Material material = materials[index];
    if (material.kind == 1) return float4(material.color.r, material.color.g, material.color.b, material.color.a);
    if ((material.kind != 2 && material.kind != 3) || material.stop_count == 0) return float4(fallback.r, fallback.g, fallback.b, fallback.a);
    float t;
    if (material.kind == 2) {
        float2 start = float2(material.start.x, material.start.y);
        float2 delta = float2(material.end.x, material.end.y) - start;
        t = clamp(dot(position - start, delta) / max(dot(delta, delta), 0.00001), 0.0, 1.0);
    } else {
        float2 local = transform_point(material.gradient_transform, position);
        float2 radial = radial_parameter(local, float2(material.start.x, material.start.y), material.color.r,
            float2(material.end.x, material.end.y), material.color.g);
        if (radial.y == 0.0) return float4(0.0, 0.0, 0.0, 0.0);
        t = clamp(radial.x, 0.0, 1.0);
    }
    GradientStop previous = gradient_stops[material.stop_start];
    [loop] for (uint i = 1; i < material.stop_count; ++i) {
        GradientStop next = gradient_stops[material.stop_start + i];
        if (t <= next.offset) {
            float amount = clamp((t - previous.offset) / max(next.offset - previous.offset, 0.00001), 0.0, 1.0);
            return lerp(float4(previous.color.r, previous.color.g, previous.color.b, previous.color.a),
                        float4(next.color.r, next.color.g, next.color.b, next.color.a), amount);
        }
        previous = next;
    }
    return float4(previous.color.r, previous.color.g, previous.color.b, previous.color.a);
}

VertexOut quad_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    uint index = payload_start + instance_id;
    Quad item = quads[index];
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    float2 transformed = active_transform(world);
    VertexOut output = { clip_position(transformed), world, transformed, local, index };
    return output;
}

float4 quad_fragment(VertexOut input) : SV_TARGET {
    Quad item = quads[input.item];
    float outer_mask = rounded_mask(input.world, item.bounds, item.radii);
    float4 fill = material_color(input.world, material_index, item.background);
    bool has_border = item.border_widths.top > 0.0 || item.border_widths.right > 0.0 ||
        item.border_widths.bottom > 0.0 || item.border_widths.left > 0.0;
    float4 result;
    if (!has_border) {
        result = float4(fill.rgb * fill.a * outer_mask, fill.a * outer_mask);
    } else {
        Rect inner;
        inner.origin.x = item.bounds.origin.x + item.border_widths.left;
        inner.origin.y = item.bounds.origin.y + item.border_widths.top;
        inner.size.width = max(0.0, item.bounds.size.width - item.border_widths.left - item.border_widths.right);
        inner.size.height = max(0.0, item.bounds.size.height - item.border_widths.top - item.border_widths.bottom);
        Radii inner_radii = {
            max(0.0, item.radii.top_left - max(item.border_widths.left, item.border_widths.top)),
            max(0.0, item.radii.top_right - max(item.border_widths.right, item.border_widths.top)),
            max(0.0, item.radii.bottom_right - max(item.border_widths.right, item.border_widths.bottom)),
            max(0.0, item.radii.bottom_left - max(item.border_widths.left, item.border_widths.bottom))
        };
        float inner_mask = inner.size.width > 0.0 && inner.size.height > 0.0 ? rounded_mask(input.world, inner, inner_radii) : 0.0;
        float border_alpha = item.border_color.a * outer_mask;
        float fill_alpha = fill.a * inner_mask;
        result.a = fill_alpha + border_alpha * (1.0 - fill_alpha);
        result.rgb = fill.rgb * fill_alpha + float3(item.border_color.r, item.border_color.g, item.border_color.b) * border_alpha * (1.0 - fill_alpha);
    }
    float coverage = clip_mask(input.transformed, clip_index) * opacity;
    return float4(result.rgb * coverage, result.a * coverage);
}

VertexOut shadow_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    uint index = payload_start + instance_id;
    Shadow item = shadows[index];
    float extent = max(0.0, item.spread + item.blur_radius * 2.0);
    float2 origin = float2(item.bounds.origin.x + item.offset.x - extent, item.bounds.origin.y + item.offset.y - extent);
    float2 size = float2(item.bounds.size.width + extent * 2.0, item.bounds.size.height + extent * 2.0);
    float2 local = corner(vertex_id);
    float2 world = origin + local * size;
    float2 transformed = active_transform(world);
    VertexOut output = { clip_position(transformed), world, transformed, local, index };
    return output;
}

float4 shadow_fragment(VertexOut input) : SV_TARGET {
    Shadow item = shadows[input.item];
    Rect bounds = item.bounds;
    bounds.origin.x += item.offset.x - item.spread;
    bounds.origin.y += item.offset.y - item.spread;
    bounds.size.width = max(0.0, bounds.size.width + item.spread * 2.0);
    bounds.size.height = max(0.0, bounds.size.height + item.spread * 2.0);
    if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) return float4(0.0, 0.0, 0.0, 0.0);
    Radii radii = {
        max(0.0, item.radii.top_left + item.spread),
        max(0.0, item.radii.top_right + item.spread),
        max(0.0, item.radii.bottom_right + item.spread),
        max(0.0, item.radii.bottom_left + item.spread)
    };
    float distance = rounded_distance(input.world, bounds, radii);
    float sigma = max(item.blur_radius * 0.5, 0.5);
    float outside = max(distance, 0.0);
    float coverage = item.blur_radius <= 0.001 ? 1.0 - smoothstep(-0.75, 0.75, distance) : exp(-0.5 * outside * outside / (sigma * sigma));
    float alpha = item.color.a * coverage * clip_mask(input.transformed, clip_index) * opacity;
    return float4(item.color.r * alpha, item.color.g * alpha, item.color.b * alpha, alpha);
}

VertexOut sprite_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    uint index = payload_start + instance_id;
    Sprite item = sprites[index];
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    float2 transformed = active_transform(world);
    VertexOut output = { clip_position(transformed), world, transformed, local, index };
    return output;
}

float4 mono_sprite_fragment(VertexOut input) : SV_TARGET {
    Sprite item = sprites[input.item];
    float2 uv = float2(item.uv_bounds.origin.x, item.uv_bounds.origin.y) + input.local * float2(item.uv_bounds.size.width, item.uv_bounds.size.height);
    float alpha = image_texture.Sample(image_sampler, uv).r * item.color.a * clip_mask(input.transformed, clip_index) * opacity;
    return float4(item.color.r * alpha, item.color.g * alpha, item.color.b * alpha, alpha);
}

float4 color_sprite_fragment(VertexOut input) : SV_TARGET {
    Sprite item = sprites[input.item];
    float2 uv = float2(item.uv_bounds.origin.x, item.uv_bounds.origin.y) + input.local * float2(item.uv_bounds.size.width, item.uv_bounds.size.height);
    float4 sampled = image_texture.Sample(image_sampler, uv);
    if (item.effect != 0) {
        float t = item.effect == 3 ? 1.0 : saturate((input.local.y * item.bounds.size.height - (item.bounds.size.height - item.effect_height)) / max(item.effect_height, 0.001));
        t = t * t * (3.0 - 2.0 * t);
        float2 delta = float2(item.uv_bounds.size.width / max(item.bounds.size.width, 0.001), item.uv_bounds.size.height / max(item.bounds.size.height, 0.001)) * item.effect_radius * t;
        float2 low = float2(item.uv_bounds.origin.x, item.uv_bounds.origin.y);
        float2 high = low + float2(item.uv_bounds.size.width, item.uv_bounds.size.height);
        float4 blurred = sampled * 0.4;
        blurred += image_texture.Sample(image_sampler, clamp(uv + float2(delta.x, 0.0), low, high)) * 0.15;
        blurred += image_texture.Sample(image_sampler, clamp(uv - float2(delta.x, 0.0), low, high)) * 0.15;
        blurred += image_texture.Sample(image_sampler, clamp(uv + float2(0.0, delta.y), low, high)) * 0.15;
        blurred += image_texture.Sample(image_sampler, clamp(uv - float2(0.0, delta.y), low, high)) * 0.15;
        float luminance = dot(blurred.rgb, float3(0.2126, 0.7152, 0.0722));
        if (item.effect == 1) blurred.rgb *= min(1.0, 0.22 / max(luminance, 0.001));
        else if (item.effect == 2) blurred.rgb = lerp(blurred.rgb, float3(1.0, 1.0, 1.0), saturate((0.72 - luminance) / max(1.0 - luminance, 0.001)));
        sampled = blurred;
        if (item.effect != 3) sampled.a *= t;
    }
    sampled.rgb *= float3(item.color.r, item.color.g, item.color.b);
    sampled.a *= item.color.a * opacity * clip_mask(input.transformed, clip_index);
    sampled.rgb *= sampled.a;
    return sampled;
}

VertexOut external_surface_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    uint index = payload_start + instance_id;
    ExternalSurface item = surfaces[index];
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    float2 transformed = active_transform(world);
    VertexOut output = { clip_position(transformed), world, transformed, local, index };
    return output;
}

float4 external_surface_fragment(VertexOut input) : SV_TARGET {
    ExternalSurface item = surfaces[input.item];
    float2 uv = float2(item.uv_bounds.origin.x, item.uv_bounds.origin.y) + input.local * float2(item.uv_bounds.size.width, item.uv_bounds.size.height);
    float4 sampled = image_texture.Sample(image_sampler, uv);
    if (item.color_space == 2) {
        sampled.rgb = max(float3(
            1.224745 * sampled.r - 0.224904 * sampled.g,
            -0.042058 * sampled.r + 1.042081 * sampled.g,
            -0.019642 * sampled.r - 0.078655 * sampled.g + 1.098537 * sampled.b), 0.0);
    } else if (item.color_space == 4) {
        float3 powered = pow(max(sampled.rgb, 0.0), 1.0 / 78.84375);
        float3 numerator = max(powered - 0.8359375, 0.0);
        float3 denominator = max(18.8515625 - 18.6875 * powered, 0.00001);
        float3 nits = 10000.0 * pow(numerator / denominator, 1.0 / 0.1593017578);
        sampled.rgb = nits / (nits + 203.0);
    } else if (item.color_space == 5) {
        float3 low = sampled.rgb * sampled.rgb / 3.0;
        float3 high = (exp((sampled.rgb - 0.55991073) / 0.17883277) + 0.28466892) / 12.0;
        sampled.rgb = lerp(low, high, step(0.5, sampled.rgb));
        sampled.rgb = sampled.rgb / (sampled.rgb + 1.0);
    }
    sampled.a *= item.opacity * opacity * clip_mask(input.transformed, clip_index);
    sampled.rgb *= sampled.a;
    return sampled;
}

VertexOut underline_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    uint index = payload_start + instance_id;
    Underline item = underlines[index];
    float2 local = corner(vertex_id);
    float2 world = float2(item.bounds.origin.x, item.bounds.origin.y) + local * float2(item.bounds.size.width, item.bounds.size.height);
    float2 transformed = active_transform(world);
    VertexOut output = { clip_position(transformed), world, transformed, local, index };
    return output;
}

float4 underline_fragment(VertexOut input) : SV_TARGET {
    Underline item = underlines[input.item];
    float center = item.bounds.origin.y + item.bounds.size.height * 0.5;
    if (item.wave_period > 0.0 && item.wave_amplitude != 0.0)
        center += sin((input.world.x - item.bounds.origin.x) * 6.28318530718 / item.wave_period) * item.wave_amplitude;
    float coverage = 1.0 - smoothstep(item.thickness * 0.5 - 0.5, item.thickness * 0.5 + 0.5, abs(input.world.y - center));
    float alpha = item.color.a * coverage * clip_mask(input.transformed, clip_index) * opacity;
    return float4(item.color.r * alpha, item.color.g * alpha, item.color.b * alpha, alpha);
}

PathOut path_vertex(uint vertex_id : SV_VertexID) {
    PathVertex item = path_vertices[payload_start + vertex_id];
    float2 world = float2(item.position.x, item.position.y);
    float2 transformed = active_transform(world);
    PathOut output = { clip_position(transformed), world, transformed, float4(item.color.r, item.color.g, item.color.b, item.color.a) };
    return output;
}

float4 path_fragment(PathOut input) : SV_TARGET {
    Color fallback = { input.color.r, input.color.g, input.color.b, input.color.a };
    float4 result = material_color(input.world, material_index, fallback);
    result.a *= clip_mask(input.transformed, clip_index) * opacity;
    result.rgb *= result.a;
    return result;
}

VertexOut composite_vertex(uint vertex_id : SV_VertexID) {
    float2 local = corner(vertex_id);
    float2 world = composite_origin + local * composite_size;
    VertexOut output = { clip_position(world), world, world, local, 0 };
    return output;
}

float4 composite_fragment(VertexOut input) : SV_TARGET {
    float4 source = image_texture.Sample(image_sampler, input.local) * opacity;
    float4 backdrop = backdrop_texture.Sample(image_sampler, input.local);
    if (blend_mode == 4)
        return min(source + backdrop, 1.0);

    float source_alpha = source.a;
    float backdrop_alpha = backdrop.a;
    float3 source_color = source_alpha > 0.000001 ? source.rgb / source_alpha : 0.0;
    float3 backdrop_color = backdrop_alpha > 0.000001 ? backdrop.rgb / backdrop_alpha : 0.0;
    float3 blended = source_color;
    if (blend_mode == 1)
        blended = source_color * backdrop_color;
    else if (blend_mode == 2)
        blended = source_color + backdrop_color - source_color * backdrop_color;
    else if (blend_mode == 3)
        blended = lerp(
            2.0 * source_color * backdrop_color,
            1.0 - 2.0 * (1.0 - source_color) * (1.0 - backdrop_color),
            step(0.5, backdrop_color));

    float4 result;
    result.rgb = (1.0 - backdrop_alpha) * source.rgb +
        (1.0 - source_alpha) * backdrop.rgb +
        source_alpha * backdrop_alpha * blended;
    result.a = source_alpha + backdrop_alpha - source_alpha * backdrop_alpha;
    return saturate(result);
}
