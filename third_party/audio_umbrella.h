/* audio_umbrella.h — single include for all vendored audio C headers.
 * Used by b.addTranslateC in build.zig to produce the audio_c Zig module.
 * Do not add IMPLEMENTATION defines here; those live in the .c shims.
 */
#include "miniaudio/miniaudio.h"
#include "dr_libs/dr_mp3.h"
