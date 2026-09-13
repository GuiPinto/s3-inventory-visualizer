#include <metal_stdlib>
using namespace metal;

struct TreemapInstance {
    float x, y, width, height;
    float sxx, sx, syy, sy;
    uint directoryId;
    uint nodeReference;
    uint timeSeconds;
    ushort extensionId;
    uchar storageClassId;
    uchar kind;
    ushort groupId;
    ushort groupPadding;
};

struct TreemapUniforms {
    float2 viewportSize;
    uint colorMode;
    uint inventoryTimestamp;
    int hoveredInstance;
    uint selectedDirectoryStart;
    uint selectedDirectoryEnd;
    int highlightCategory;

    // Bit 0 draws guide lines out to the canvas edges, for a selection too small to spot on its own.
    uint selectionFlags;

    // The rectangle to outline, in layout pixels. A zero width means nothing is selected.
    float selectionX;
    float selectionY;
    float selectionWidth;
    float selectionHeight;
};

struct TransitionUniforms {
    float2 translation;
    float scale;
    float opacity;
};

struct VertexOut {
    float4 position [[position]];
    float2 localPosition;
    float2 globalPosition;
    float4 baseColor;
    float shading;
    float dim;
    float selected;
    float isRemainder;
    float sxx, sx, syy, sy;
    float2 cellSize;
};

static uint ageBucketOf(uint timeSeconds, uint inventoryTimestamp) {
    uint age = inventoryTimestamp > timeSeconds ? (inventoryTimestamp - timeSeconds) / 86400u : 0u;
    if (age < 30u) { return 0u; }
    if (age < 90u) { return 1u; }
    if (age < 180u) { return 2u; }
    if (age < 365u) { return 3u; }
    if (age < 730u) { return 4u; }
    if (age < 1095u) { return 5u; }
    if (age < 1825u) { return 6u; }
    return 7u;
}

constant uint folderColorCount = 20u;
/// Matches TreemapPalette.canvasBackground. The gutters between tiles are drawn in it.
constant float3 canvasBackground = float3(0x16 / 255.0, 0x18 / 255.0, 0x1D / 255.0);

static float4 colorForInstance(
    constant TreemapInstance &instance,
    constant TreemapUniforms &uniforms,
    constant float4 *storageClassColors,
    constant float4 *extensionColors,
    constant float4 *ageColors,
    constant uchar *extensionSlots,
    constant float4 *folderColors
) {
    if (uniforms.colorMode == 0u) {
        return storageClassColors[min(uint(instance.storageClassId), 7u)];
    }

    if (uniforms.colorMode == 1u) {
        uchar slot = extensionSlots[instance.extensionId];
        return slot >= 15 ? extensionColors[15] : extensionColors[slot];
    }

    if (uniforms.colorMode == 3u) {
        // A rank past the palette, and 0xFFFF for a cell owned by the view root itself, both take the
        // neutral colour. Only the largest folders earn a hue; the rest are too small to tell apart.
        if (uint(instance.groupId) >= folderColorCount) {
            return folderColors[folderColorCount];
        }

        return folderColors[uint(instance.groupId)];
    }

    return ageColors[ageBucketOf(instance.timeSeconds, uniforms.inventoryTimestamp)];
}

static int categoryOfInstance(
    constant TreemapInstance &instance,
    constant TreemapUniforms &uniforms,
    constant uchar *extensionSlots
) {
    if (uniforms.colorMode == 0u) {
        return int(instance.storageClassId);
    }

    if (uniforms.colorMode == 1u) {
        return int(extensionSlots[instance.extensionId]);
    }

    if (uniforms.colorMode == 3u) {
        return uint(instance.groupId) >= folderColorCount ? -2 : int(instance.groupId);
    }

    return int(ageBucketOf(instance.timeSeconds, uniforms.inventoryTimestamp));
}

vertex VertexOut treemapVertex(
    uint vertexIdentifier [[vertex_id]],
    uint instanceIdentifier [[instance_id]],
    constant TreemapInstance *instances [[buffer(0)]],
    constant TreemapUniforms &uniforms [[buffer(1)]],
    constant float4 *storageClassColors [[buffer(2)]],
    constant float4 *extensionColors [[buffer(3)]],
    constant float4 *ageColors [[buffer(4)]],
    constant uchar *extensionSlots [[buffer(5)]],
    constant TransitionUniforms &transition [[buffer(6)]],
    constant float4 *folderColors [[buffer(7)]]
) {
    constant TreemapInstance &instance = instances[instanceIdentifier];
    // Triangle strip order: (0,0), (1,0), (0,1), (1,1).
    float2 corner = float2(float(vertexIdentifier & 1u), float((vertexIdentifier >> 1) & 1u));

    // Squarified rectangles land on fractional pixels, so their one pixel gutters were being spread
    // across two pixels by differing amounts and shimmered as a moire. Both EDGES are snapped to whole
    // pixels, never the width: a tile's right edge and its neighbour's left edge are the same float, so
    // they snap to the same integer and the two still meet exactly. Skipped while a zoom is animating,
    // where snapping every frame would make the motion jitter.
    float2 lower = float2(instance.x, instance.y);
    float2 upper = lower + float2(instance.width, instance.height);

    if (transition.scale == 1.0) {
        lower = round(lower);
        upper = max(round(upper), lower + 1.0);
    }

    float2 cellSize = upper - lower;
    float2 pixel = mix(lower, upper, corner);
    float2 transformed = pixel * transition.scale + transition.translation;
    float2 normalized = transformed / uniforms.viewportSize;

    VertexOut out;
    out.position = float4(normalized.x * 2.0 - 1.0, 1.0 - normalized.y * 2.0, 0.0, 1.0);
    out.localPosition = corner * cellSize;
    out.globalPosition = pixel;
    out.baseColor = colorForInstance(
        instance,
        uniforms,
        storageClassColors,
        extensionColors,
        ageColors,
        extensionSlots,
        folderColors
    );
    out.baseColor.a = transition.opacity;
    out.shading = (int(instanceIdentifier) == uniforms.hoveredInstance) ? 1.35 : 1.0;

    float dim = 0.0;
    float selected = 0.0;

    if (uniforms.selectedDirectoryEnd > uniforms.selectedDirectoryStart) {
        bool inside = instance.directoryId >= uniforms.selectedDirectoryStart
                   && instance.directoryId < uniforms.selectedDirectoryEnd;
        dim = inside ? 0.0 : 0.60;
        selected = inside ? 1.0 : 0.0;
    }

    out.selected = selected;

    if (uniforms.highlightCategory >= 0
        && categoryOfInstance(instance, uniforms, extensionSlots) != uniforms.highlightCategory) {
        dim = max(dim, 0.7);
    }

    out.dim = dim;
    out.isRemainder = (instance.kind == 2) ? 1.0 : 0.0;
    out.sxx = instance.sxx;
    out.sx = instance.sx;
    out.syy = instance.syy;
    out.sy = instance.sy;
    out.cellSize = cellSize;
    return out;
}

fragment float4 treemapFragment(
    VertexOut in [[stage_in]],
    constant TreemapUniforms &uniforms [[buffer(1)]]
) {
    float3 color = in.baseColor.rgb;

    if (in.isRemainder > 0.5) {
        // A flat hatch: the cell reads as "more here" without pretending to be a moulded surface.
        float stripe = fract((in.globalPosition.x + in.globalPosition.y) * 0.1);
        color = mix(color, canvasBackground, stripe < 0.5 ? 0.32 : 0.58);
    } else {
        // The instance still carries the cushion coefficients sxx, sx, syy and sy. Shading by them
        // instead of the line below restores the moulded WinDirStat surface, at the cost of a fill
        // that no longer matches its legend swatch.
        // Barely a shade, two percent top to bottom. Enough that a large block is not a dead slab,
        // small enough that the fill still reads as the legend swatch.
        float vertical = in.cellSize.y > 1.0 ? clamp(in.localPosition.y / in.cellSize.y, 0.0, 1.0) : 0.5;
        color *= mix(1.02, 0.98, vertical);
    }

    // Blending toward white rather than multiplying: a flat fill is already near its full value, so a
    // multiply would clip the bright channels and shift the hue.
    if (in.shading > 1.0) {
        color = mix(color, float3(1.0), 0.22);
    }

    if (in.selected > 0.5) {
        color = mix(color, float3(1.0), 0.12);
    }

    if (in.dim > 0.0) {
        float grey = dot(color, float3(0.299, 0.587, 0.114));
        color = mix(color, float3(grey * 0.45), in.dim);
    }

    // A bright ring straddling the border of the selected rectangle. It is drawn on both sides of the
    // border so that a selection only a pixel or two across is still clearly marked.
    if (uniforms.selectionWidth > 0.0 && uniforms.selectionHeight > 0.0) {
        float2 halfSize = float2(uniforms.selectionWidth, uniforms.selectionHeight) * 0.5;
        float2 center = float2(uniforms.selectionX, uniforms.selectionY) + halfSize;
        float2 offset = abs(in.globalPosition - center) - halfSize;
        float outside = length(max(offset, 0.0));
        float insideDistance = min(max(offset.x, offset.y), 0.0);
        float signedDistance = outside + insideDistance;
        float thickness = 3.0;
        float ring = 1.0 - smoothstep(thickness * 0.55, thickness, abs(signedDistance));
        // A dark halo just outside the ring keeps it readable over a bright cell.
        float halo = (1.0 - smoothstep(thickness, thickness * 2.4, abs(signedDistance))) * (1.0 - ring);

        // Guide lines run from the marker to the edges of the canvas, so a cell a couple of pixels
        // wide can be found at a glance instead of hunted for.
        if ((uniforms.selectionFlags & 1u) != 0u && signedDistance > thickness) {
            float2 distanceToAxis = abs(in.globalPosition - center);
            float axis = min(distanceToAxis.x, distanceToAxis.y);
            float guide = (1.0 - smoothstep(0.8, 2.2, axis));
            if (guide > 0.0) {
                color = mix(color, float3(0.02, 0.02, 0.03), guide * 0.55);
                float core = 1.0 - smoothstep(0.0, 1.0, axis);
                color = mix(color, float3(1.0, 0.98, 0.86), core * 0.85);
            }
        }

        if (halo > 0.0) {
            color = mix(color, float3(0.03, 0.03, 0.04), halo * 0.75);
        }

        if (ring > 0.0) {
            color = mix(color, float3(1.0, 1.0, 0.94), ring);
        }
    }

    // A gutter in the canvas colour rather than a darkened rim. It reads as a gap between tiles,
    // which is what separates them in a flat design, and it keeps the fill itself untinted.
    float alpha = in.baseColor.a;
    // Exactly one pixel of gutter, hard edged, on the right and bottom only. Both the tile and the
    // gutter sit on the pixel grid, so no anti-aliasing is needed and none of it shimmers. Drawing it
    // on one side is also what keeps dense regions bright: a gutter on all four sides costs a three
    // pixel tile 89 percent of its colour, where one side costs it 56 percent, and neighbours still
    // end up separated by a single clean line.
    if (in.cellSize.x >= 2.0 && in.cellSize.y >= 2.0) {
        bool onGutter = (in.cellSize.x - in.localPosition.x) < 1.0
                     || (in.cellSize.y - in.localPosition.y) < 1.0;

        if (onGutter) {
            // One pixel is a quarter of a two pixel tile, so a gutter at full strength turns a dense
            // region into dark speckle. It fades in with the tile: invisible on the smallest tiles,
            // which read as a solid field of colour, and fully drawn once there is room for it.
            float smallestSide = min(in.cellSize.x, in.cellSize.y);
            float strength = clamp((smallestSide - 2.0) / 6.0, 0.0, 1.0) * 0.82;
            color = mix(color, canvasBackground, strength);
        }
    }

    // Rounded corners on the cells big enough to show them. Smaller tiles stay square, because a
    // radius on a four pixel cell only eats the cell.
    if (in.cellSize.x >= 16.0 && in.cellSize.y >= 16.0) {
        float radius = 3.0;
        float2 halfSize = in.cellSize * 0.5;
        float2 offset = abs(in.localPosition - halfSize) - (halfSize - radius);
        float corner = length(max(offset, 0.0)) - radius;
        alpha *= 1.0 - smoothstep(-0.6, 0.6, corner);
    }

    return float4(clamp(color, 0.0, 1.0), alpha);
}
