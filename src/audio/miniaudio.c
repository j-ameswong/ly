// Compiles the miniaudio implementation, along with stb_vorbis so that Ogg
// Vorbis files can be decoded on top of the built-in WAV, FLAC and MP3
// decoders.

#define STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio_config.h"

// The stb_vorbis implementation must come after the miniaudio one
#undef STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"
