// Debug-only: lets XCUITests open Screens A via `-screen=<name>` without editing CueCoach/App.
#if DEBUG
extern void cc_screensA_installDebugRouter(void);

__attribute__((constructor)) static void cc_screensA_boot(void) {
    cc_screensA_installDebugRouter();
}
#endif
