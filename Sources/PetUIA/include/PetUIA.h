#ifndef PET_UIA_H
#define PET_UIA_H

#include <stdint.h>
#include <wchar.h>

/// Windows only (built for pet-emit --jump; the Mac build does not include this target).
///
/// Selects the tab named exactly `name` in the top-level window `window` (a Windows Terminal
/// window), through UI Automation. Retries until `timeout_ms` has passed, since the terminal
/// renames its tab a moment after the title changes.
/// With `retitle` set, the calling process's console title is set to `name` before every try:
/// a busy program (Claude Code animates its title) would otherwise write over it before the
/// terminal showed it.
/// Returns 1 when a tab was selected, 0 when none had that name, negative on a COM failure.
int pet_uia_select_tab(intptr_t window, const wchar_t *name, int timeout_ms, int retitle);

#endif
