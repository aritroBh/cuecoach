// Debug-only hook: lets XCUITests open Screens B via `-screen=<name>` without editing App/HomeView.
// Calls into Swift (`ScreensBDebugRouter.swift`), which does nothing unless the launch argument names one of its screens.
#if DEBUG
extern void cuecoach_screensb_debug_boot(void);
__attribute__((constructor)) static void screensb_debug_boot(void) { cuecoach_screensb_debug_boot(); }
#endif
