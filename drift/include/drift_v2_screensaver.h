#ifndef DRIFT_V2_SCREENSAVER_H
#define DRIFT_V2_SCREENSAVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DriftPresetOriginal  = 0,
    DriftPresetPlasma    = 1,
    DriftPresetPoolside  = 2,
    DriftPresetGumdrop   = 3,
    DriftPresetSilver    = 4,
    DriftPresetFreedom   = 5,
    DriftPresetSpaceGray = 6,
    DriftPresetAurora    = 7,
    DriftPresetAtlas     = 8,
    DriftPresetEmerald   = 9,
    DriftPresetGlacier   = 10,
    DriftPresetEmber     = 11,
} DriftPreset;

typedef struct DriftHandle DriftHandle;

/* `scale_factor` is device pixels per logical unit. The engine's sizes (line
 * width and spacing, flow features) are in logical units, so the caller picks
 * this to make a logical unit the same physical size on every display. */

DriftHandle *drift_create(void *ns_view,
                           uint32_t physical_width,
                           uint32_t physical_height,
                           float scale_factor,
                           uint32_t preset,
                           uint32_t is_preview);

void drift_animate(DriftHandle *handle);

void drift_resize(DriftHandle *handle,
                  uint32_t physical_width,
                  uint32_t physical_height,
                  float scale_factor);

void drift_set_preset(DriftHandle *handle, uint32_t preset);

void drift_destroy(DriftHandle *handle);

#ifdef __cplusplus
}
#endif

#endif /* DRIFT_V2_SCREENSAVER_H */
