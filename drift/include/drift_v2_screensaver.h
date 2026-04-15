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
} DriftPreset;

typedef struct DriftHandle DriftHandle;

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
