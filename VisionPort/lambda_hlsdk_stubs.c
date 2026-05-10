// HLSDK stubs for cl_dll-side globals referenced by pm_shared.c when it
// is also pulled into the server (dlls/) build. The cl_dll build defines
// these in cl_dll/view.cpp and cl_dll/in_camera.cpp; we don't link cl_dll
// today, so PM_SpectatorMove's spectator-jump fast path never fires
// during normal gameplay — but the linker still needs symbols to bind.
//
// Once cl_dll is statically linked alongside dlls (post-renderer wiring),
// drop this file and let the real definitions take over.

float vJumpOrigin[3];
float vJumpAngles[3];
int   iJumpSpectator;
