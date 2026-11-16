// miniaudio build configuration shared by the C implementation
// (miniaudio.c) and the header translated for Zig, so that both agree on
// which parts of the library exist.

#ifndef LY_MINIAUDIO_CONFIG_H
#define LY_MINIAUDIO_CONFIG_H

// We only ever decode a file and play it back
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER

// A JACK server has no business running underneath a display manager
#define MA_NO_JACK

#include "miniaudio.h"

#endif
