// ============================================================================
// Hooks_NoARC.m - Compiled WITHOUT ARC
//
// These hooks handle Swift value-type parameters that crash under ARC because
// objc_retain is called on non-ObjC objects.
//
// IDA ANALYSIS RESULTS (from CameraUI in iOS 26 dyld shared cache):
//
//   CAMNightModeDurationMapping (16 bytes):
//     - Two doubles passed in D0 + D1 (ARM64 HFA convention)
//     - D0 = autoDuration, D1 = maxDuration
//     - Getter: LDP D0, D1, [X8]
//     - Setter: STP D0, D1, [X8]
//
//   CAMNightModeStatus (8 bytes):
//     - Single QWORD passed in X2/X3 (integer register)
//     - Values: -1 = invalid, 0 = off, >0 = active mode
//     - Stored at offset 0x40 in CUCaptureController
//
//   CAMNightModeDurationForMode(int64 mode, double autoDur, double maxDur):
//     - mode 0 (Off)  → returns 0.0
//     - mode 1 (Auto) → returns autoDur (D0)
//     - mode 2 (Max)  → returns maxDur  (D1)
//
// The ISP sends duration mapping (auto + max durations) via
// captureController:didOutputNightModeDurationMapping: using D0+D1 registers.
// We override D1 (maxDuration) to gMaxDuration.
// ============================================================================

#import <objc/runtime.h>
#import <objc/message.h>
#import "NMEShared.h"

// CydiaSubstrate
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

// ============================================================================
#pragma mark - captureController:didOutputNightModeDurationMapping:
// ============================================================================
// ARM64 calling convention for this method:
//   X0 = self (CAMViewfinderViewController)
//   X1 = _cmd
//   X2 = captureController (id)
//   D0 = autoDuration (double)  ← first member of CAMNightModeDurationMapping
//   D1 = maxDuration  (double)  ← second member of CAMNightModeDurationMapping
//
// We override D1 (maxDuration) to gMaxDuration when in Max mode.

static IMP orig_VF_didOutputDurationMapping;

static void hook_VF_didOutputDurationMapping(
    id self, SEL _cmd, id controller,
    double autoDuration, double maxDuration)
{
    if (gTweakEnabled && maxDuration > 0) {
        maxDuration = gMaxDuration;
    }
    ((void (*)(id, SEL, id, double, double))orig_VF_didOutputDurationMapping)(
        self, _cmd, controller, autoDuration, maxDuration);
}

// ============================================================================
#pragma mark - _setNightModeDurationMapping: on ViewfinderViewController
// ============================================================================
// ARM64 calling convention:
//   X0 = self
//   X1 = _cmd
//   D0 = autoDuration
//   D1 = maxDuration
//
// We override D1 (maxDuration) to ensure every mapping store uses our value.

static IMP orig_VF_setDurationMapping;

static void hook_VF_setDurationMapping(
    id self, SEL _cmd,
    double autoDuration, double maxDuration)
{
    if (gTweakEnabled && maxDuration > 0) {
        maxDuration = gMaxDuration;
    }
    ((void (*)(id, SEL, double, double))orig_VF_setDurationMapping)(
        self, _cmd, autoDuration, maxDuration);
}

// ============================================================================
#pragma mark - _nightModeDurationMapping getter on ViewfinderViewController
// ============================================================================
// ARM64 return convention for HFA {double, double}:
//   D0 = autoDuration (returned)
//   D1 = maxDuration  (returned)
//
// We need a struct to capture both return values.

typedef struct {
    double autoDuration;
    double maxDuration;
} NMEDurationMapping;

static IMP orig_VF_getDurationMapping;

static NMEDurationMapping hook_VF_getDurationMapping(id self, SEL _cmd)
{
    NMEDurationMapping result =
        ((NMEDurationMapping (*)(id, SEL))orig_VF_getDurationMapping)(self, _cmd);
    if (gTweakEnabled && result.maxDuration > 0) {
        result.maxDuration = gMaxDuration;
    }
    return result;
}

// ============================================================================
#pragma mark - captureController:didOutputNightModeStatus:
// ============================================================================
// ARM64 calling convention:
//   X0 = self
//   X1 = _cmd
//   X2 = captureController (id)
//   X3 = nightModeStatus (int64_t, 8-byte QWORD)
//
// Status values: -1 = invalid, 0 = off, >0 = active
// We don't modify the status itself, but keep the hook for safety (non-ARC).

static IMP orig_VF_didOutputNightModeStatus;

static void hook_VF_didOutputNightModeStatus(
    id self, SEL _cmd, id controller, long long nightModeStatus)
{
    ((void (*)(id, SEL, id, long long))orig_VF_didOutputNightModeStatus)(
        self, _cmd, controller, nightModeStatus);
}

// ============================================================================
#pragma mark - Initialization
// ============================================================================

void NMEInstallNoARCHooks(void) {
    Class vfClass = objc_getClass("CAMViewfinderViewController");
    if (!vfClass) return;

    // Hook captureController:didOutputNightModeDurationMapping:
    // This is called when the ISP sends new duration values.
    {
        SEL sel = sel_registerName("captureController:didOutputNightModeDurationMapping:");
        if (class_getInstanceMethod(vfClass, sel)) {
            MSHookMessageEx(vfClass, sel,
                            (IMP)hook_VF_didOutputDurationMapping,
                            &orig_VF_didOutputDurationMapping);
        }
    }

    // Hook _setNightModeDurationMapping:
    // This stores the mapping in the VC's ivar.
    {
        SEL sel = sel_registerName("_setNightModeDurationMapping:");
        if (class_getInstanceMethod(vfClass, sel)) {
            MSHookMessageEx(vfClass, sel,
                            (IMP)hook_VF_setDurationMapping,
                            &orig_VF_setDurationMapping);
        }
    }

    // Hook _nightModeDurationMapping (getter)
    // This is read when starting the countdown and other places.
    {
        SEL sel = sel_registerName("_nightModeDurationMapping");
        if (class_getInstanceMethod(vfClass, sel)) {
            MSHookMessageEx(vfClass, sel,
                            (IMP)hook_VF_getDurationMapping,
                            &orig_VF_getDurationMapping);
        }
    }

    // Hook captureController:didOutputNightModeStatus:
    // Non-ARC passthrough to prevent ARC crash on Swift value type.
    {
        SEL sel = sel_registerName("captureController:didOutputNightModeStatus:");
        if (class_getInstanceMethod(vfClass, sel)) {
            MSHookMessageEx(vfClass, sel,
                            (IMP)hook_VF_didOutputNightModeStatus,
                            &orig_VF_didOutputNightModeStatus);
        }
    }
}
