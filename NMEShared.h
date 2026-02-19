#import <Foundation/Foundation.h>

// Shared state between ARC (Tweak.x) and non-ARC (Hooks_NoARC.m) files
extern BOOL gTweakEnabled;
extern double gMaxDuration;
extern long long gResolvedNightModeControlMode;

// Multi-capture chaining state (for breaking ISP's ~30s limit)
extern BOOL gNMEExtendedCaptureActive;
extern double gNMECaptureStartTime;

// Called from %ctor to install non-ARC hooks
void NMEInstallNoARCHooks(void);
