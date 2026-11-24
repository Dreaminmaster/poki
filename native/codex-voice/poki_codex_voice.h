#ifndef POKI_CODEX_VOICE_H
#define POKI_CODEX_VOICE_H

#include <stdbool.h>

typedef void (*PokiCodexEvent)(const char *message);

bool poki_codex_start(const char *home, PokiCodexEvent event);
bool poki_codex_send(const char *message);

#endif
