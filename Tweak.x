#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "NMEShared.h"

// ============================================================================
// NightModeExtender - Extend Night Mode exposure up to 5 minutes (300s)
// for astrophotography (stars, Milky Way, long exposure)
//
// iOS 15-18: LowLight prefix → extend slider durationMapping.
// iOS 26+:   NightMode prefix → Off/Auto/Max button (no slider).
//            "Max" is ISP-suggested (10-30s depending on light).
//            The ISP independently controls actual capture duration.
//            We break the ISP limit by SEAMLESSLY chaining capture cycles:
//              - When one ISP cycle finishes (~30s), we SUPPRESS the
//                completion callback and silently re-trigger another capture
//              - The UI (countdown, alignment guide, spinner) stays alive
//                continuously - user sees no interruption
//              - Only when the total countdown reaches 0 do we let the
//                final completion through, ending the capture
//              - Each ISP cycle saves a photo silently in the background
// ============================================================================

// -- Shared globals (accessed from Hooks_NoARC.m via NMEShared.h) --
BOOL gTweakEnabled = YES;
double gMaxDuration = 300.0;
long long gResolvedNightModeControlMode = 0;

// -- Multi-capture chaining state --
BOOL gNMEExtendedCaptureActive = NO;
double gNMECaptureStartTime = 0;
static BOOL sNMEIsRetriggering = NO;   // suppresses sound/animation on re-trigger

// -- Preferences --
static NSString *const kPrefsDomain = @"com.34306.nightmodeextender";

static void loadPreferences(void) {
    NSDictionary *prefs = nil;
    NSArray *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.34306.nightmodeextender.plist",
        @"/var/mobile/Library/Preferences/com.34306.nightmodeextender.plist"
    ];
    for (NSString *path in paths) {
        prefs = [NSDictionary dictionaryWithContentsOfFile:path];
        if (prefs) break;
    }

    if (prefs) {
        id enabled = prefs[@"enabled"];
        gTweakEnabled = enabled ? [enabled boolValue] : YES;
        id maxDur = prefs[@"maxDuration"];
        gMaxDuration = maxDur ? [maxDur doubleValue] : 300.0;
    } else {
        gTweakEnabled = YES;
        gMaxDuration = 300.0;
    }
    if (gMaxDuration < 10.0) gMaxDuration = 10.0;
    if (gMaxDuration > 600.0) gMaxDuration = 600.0;
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object,
                                  CFDictionaryRef userInfo) {
    loadPreferences();
}

// ---------------------------------------------------------------------------
// Helper: remaining time in extended capture session
// ---------------------------------------------------------------------------
static double NMERemainingTime(void) {
    if (!gNMEExtendedCaptureActive || gNMECaptureStartTime <= 0) return gMaxDuration;
    double elapsed = CFAbsoluteTimeGetCurrent() - gNMECaptureStartTime;
    double remaining = gMaxDuration - elapsed;
    return remaining > 0 ? remaining : 0;
}

// ---------------------------------------------------------------------------
// Helper: build an extended duration array up to gMaxDuration
// ---------------------------------------------------------------------------
static NSArray<NSNumber *> *ExtendedDurationMapping(NSArray<NSNumber *> *original) {
    if (!gTweakEnabled) return original;
    if (!original || original.count == 0) return original;

    NSMutableArray<NSNumber *> *extended = [NSMutableArray arrayWithArray:original];
    double last = [[extended lastObject] doubleValue];
    if (last >= gMaxDuration) return original;

    double steps[] = { 30, 45, 60, 90, 120, 150, 180, 210, 240, 270, 300, 360, 420, 480, 540, 600 };
    for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
        if (steps[i] > last && steps[i] <= gMaxDuration) {
            [extended addObject:@(steps[i])];
        }
    }
    if ([[extended lastObject] doubleValue] < gMaxDuration) {
        [extended addObject:@(gMaxDuration)];
    }
    return [extended copy];
}

// ============================================================================
#pragma mark - Forward declarations
// ============================================================================

@interface CAMLowLightSlider : UIView
@property (nonatomic, copy) NSArray *durationMapping;
@end

@interface CAMLowLightStatusIndicator : UIView
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) long long lowLightMode;
@end

@interface CAMNightModeSlider : UIView
@property (nonatomic, copy) NSArray *durationMapping;
@end

@interface CAMNightModeStatusIndicator : UIView
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) long long nightMode;
@property (nonatomic, assign) BOOL nightModeDisabled;
@end

@interface CAMNightModeInstructionLabel : UIView
- (void)countDownFrom:(double)seconds;
@end

@interface CAMViewfinderViewController : UIViewController
- (long long)_resolvedNightModeControlMode;
- (long long)_resolvedNightMode;
- (BOOL)_isExpectedNightModeDurationCancelable;
- (void)_captureStillImageWithCurrentSettings;
- (BOOL)_isNightModeCaptureUIVisible;
- (void)_setNightModeCaptureUIVisible:(BOOL)visible;
- (void)_beginNightModeInstructionLabelCountDown;
- (void)_setCurrentNightModeCaptureCancelable:(BOOL)cancelable;
- (void)updateControlVisibilityAnimated:(BOOL)animated;
- (void)_updateResolvedNightModeAnimated:(BOOL)animated;
@end

@interface CAMStillImageCaptureResolvedSettings : NSObject
@end

@interface CAMCaptureCapabilities : NSObject
@end

@interface CAMMutableStillImageCaptureRequest : NSObject
- (long long)nightMode;
@end

// ============================================================================
#pragma mark - iOS 15-18 hooks (LowLight naming)
// ============================================================================

%group iOS15_18

%hook CAMLowLightSlider
- (void)setDurationMapping:(NSArray *)mapping { %orig(ExtendedDurationMapping(mapping)); }
- (NSArray *)durationMapping { return ExtendedDurationMapping(%orig); }
%end

%hook CAMViewfinderViewController
- (void)setLowLightDurationMapping:(NSArray *)mapping { %orig(ExtendedDurationMapping(mapping)); }
%end

%hook CAMStillImageCaptureResolvedSettings
- (double)lowLightCaptureTime {
    if (!gTweakEnabled) return %orig;
    double orig = %orig;
    if (orig > 0 && orig < gMaxDuration) return gMaxDuration;
    return orig;
}
%end

%hook CAMLowLightStatusIndicator
- (void)setDuration:(double)duration { %orig(duration); }
%end

%hook CAMCaptureCapabilities
- (BOOL)backLowLightSupported { return YES; }
- (BOOL)frontLowLightSupported { return YES; }
%end

%end // iOS15_18

// ============================================================================
#pragma mark - iOS 26+ hooks (NightMode naming)
// ============================================================================

%group iOS26

// -- Slider (code exists internally, extend its mapping) --

%hook CAMNightModeSlider
- (void)setDurationMapping:(NSArray *)mapping { %orig(ExtendedDurationMapping(mapping)); }
- (NSArray *)durationMapping { return ExtendedDurationMapping(%orig); }
%end

// -- ViewfinderViewController: seamless multi-capture chaining --

%hook CAMViewfinderViewController

- (void)handleUserChangedToNightMode:(long long)mode {
    %orig;
    if ([self respondsToSelector:@selector(_resolvedNightModeControlMode)]) {
        gResolvedNightModeControlMode = [self _resolvedNightModeControlMode];
    } else {
        gResolvedNightModeControlMode = mode;
    }
}

- (void)_updateNightModeControlsAnimated:(BOOL)animated {
    %orig;
    if ([self respondsToSelector:@selector(_resolvedNightModeControlMode)]) {
        gResolvedNightModeControlMode = [self _resolvedNightModeControlMode];
    }
}

- (void)_updateResolvedNightModeAnimated:(BOOL)animated {
    if (gTweakEnabled && gNMEExtendedCaptureActive) {
        // CRITICAL: Suppress ISP status updates during extended capture.
        // After each ISP cycle, nightModeStatus changes → _resolvedNightMode
        // would be recalculated to 0 (off) → re-triggered capture would have
        // nightMode=0 → instant regular photo instead of night mode.
        return;
    }
    %orig;
    if ([self respondsToSelector:@selector(_resolvedNightModeControlMode)]) {
        gResolvedNightModeControlMode = [self _resolvedNightModeControlMode];
    }
}

// CRITICAL: Force night mode to stay at Max (2) during extended capture.
// Without this, ISP status updates reset _resolvedNightMode to 0 after each
// cycle, causing re-triggered captures to be regular (non-night-mode) photos.
- (long long)_resolvedNightMode {
    if (gTweakEnabled && gNMEExtendedCaptureActive) return 2;
    return %orig;
}

// Always allow cancellation for extended captures
- (BOOL)_isExpectedNightModeDurationCancelable {
    if (gTweakEnabled && gResolvedNightModeControlMode >= 2) return YES;
    return %orig;
}

// ---- FIRST capture cycle: record start time, let UI set up normally ----

- (void)stillImageRequestDidStartCapturing:(id)request resolvedSettings:(id)settings {
    if (gTweakEnabled && gResolvedNightModeControlMode >= 2) {
        if (sNMEIsRetriggering) {
            // Re-triggered cycle: SUPPRESS all UI setup (countdown, animation, etc.)
            // The UI is already showing from the first cycle - keep it as-is
            sNMEIsRetriggering = NO;
            return;
        }
        if (!gNMEExtendedCaptureActive) {
            // First cycle: start tracking, let %orig show the UI
            gNMEExtendedCaptureActive = YES;
            gNMECaptureStartTime = CFAbsoluteTimeGetCurrent();
        }
    }
    %orig;
}

// ---- ISP cycle ended: suppress completion and re-trigger silently ----

- (void)stillImageRequestDidStopCapturingStillImage:(id)request {
    if (gTweakEnabled && gNMEExtendedCaptureActive && gResolvedNightModeControlMode >= 2) {
        double remaining = NMERemainingTime();

        if (remaining > 5.0) {
            // Time remaining - DON'T call %orig (keeps UI alive: countdown,
            // alignment guide, shutter spinner all stay visible)
            // The photo was already saved by didFinishProcessingPhoto.
            // CUCaptureController already cleared _capturingNightModeStillImageRequest.

            // Re-trigger next capture cycle silently after all completion
            // callbacks have settled (inflight count decremented, state cleared)
            __weak CAMViewfinderViewController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CAMViewfinderViewController *strongSelf = weakSelf;
                if (strongSelf && gNMEExtendedCaptureActive) {
                    sNMEIsRetriggering = YES;
                    [strongSelf _captureStillImageWithCurrentSettings];
                }
            });
            return;  // Suppress %orig - UI stays alive
        }
        // Countdown reached 0 - end extended capture, let final cleanup through
        gNMEExtendedCaptureActive = NO;
        gNMECaptureStartTime = 0;
    }
    %orig;
}

// ---- Suppress shutter sound on silent re-triggers ----

- (void)_playCaptureSoundUsingCurrentHeadphonesCaptureEventIfAvailable {
    if (sNMEIsRetriggering) return;  // Silent re-trigger
    %orig;
}

// ---- Cancellation: shutter tap stops the extended capture ----

- (void)_handleShutterButtonActionWithEventTriggerDescription:(id)desc {
    if (gTweakEnabled && gNMEExtendedCaptureActive) {
        // User tapped shutter during extended capture - cancel
        gNMEExtendedCaptureActive = NO;
        gNMECaptureStartTime = 0;
        // Don't call %orig - just let the current ISP cycle finish,
        // and when it does, stillImageRequestDidStopCapturingStillImage
        // will see gNMEExtendedCaptureActive=NO and call %orig normally
        return;
    }
    %orig;
}

%end

// -- ResolvedSettings: inject extended duration at creation AND getter --

%hook CAMStillImageCaptureResolvedSettings

- (id)initWithHDREnabled:(BOOL)hdr
      portraitEffectEnabled:(BOOL)portrait
      nightModeCaptureTime:(double)captureTime
      nightModePreviewColorEstimate:(id)colorEstimate
      nightModeCaptureHasInitialPreviewFeedbackSensitivity:(BOOL)initialFeedback
      nightModeCaptureHasConstantPreviewFeedbackSensitivity:(BOOL)constantFeedback
      captureBeforeResolvingSettingsEnabled:(BOOL)captureBeforeResolving {
    if (gTweakEnabled && gResolvedNightModeControlMode >= 2 && captureTime > 0) {
        if (gNMEExtendedCaptureActive) {
            captureTime = NMERemainingTime();
            if (captureTime < 1.0) captureTime = gMaxDuration;
        } else {
            captureTime = gMaxDuration;
        }
    }
    return %orig(hdr, portrait, captureTime, colorEstimate, initialFeedback, constantFeedback, captureBeforeResolving);
}

- (double)nightModeCaptureTime {
    if (!gTweakEnabled) return %orig;
    double orig = %orig;
    if (gResolvedNightModeControlMode >= 2 && orig > 0) {
        if (gNMEExtendedCaptureActive) {
            double remaining = NMERemainingTime();
            return remaining > 0 ? remaining : gMaxDuration;
        }
        return gMaxDuration;
    }
    return orig;
}

%end

// -- Status indicator: show remaining time during extended capture --

%hook CAMNightModeStatusIndicator
- (void)setDuration:(double)duration {
    if (gTweakEnabled && gResolvedNightModeControlMode >= 2 && duration > 0) {
        if (gNMEExtendedCaptureActive) {
            double remaining = NMERemainingTime();
            %orig(remaining > 0 ? remaining : gMaxDuration);
        } else {
            %orig(gMaxDuration);
        }
    } else {
        %orig(duration);
    }
}
%end

// -- Countdown label: show remaining time during extended capture --

%hook CAMNightModeInstructionLabel
- (void)countDownFrom:(double)seconds {
    if (gTweakEnabled && gResolvedNightModeControlMode >= 2 && seconds > 0) {
        if (gNMEExtendedCaptureActive) {
            double remaining = NMERemainingTime();
            %orig(remaining > 0 ? remaining : gMaxDuration);
        } else {
            %orig(gMaxDuration);
        }
    } else {
        %orig(seconds);
    }
}
%end

// -- Capabilities: force night mode supported everywhere --

%hook CAMCaptureCapabilities
- (BOOL)isBackNightModeSupported { return YES; }
- (BOOL)isFrontNightModeSupported { return YES; }
- (BOOL)isNightModeSupported { return YES; }
- (BOOL)isNightModeSupportedForMode:(long long)mode device:(long long)device { return YES; }
- (BOOL)isNightModeSupportedForMode:(long long)mode device:(long long)device zoomFactor:(double)zoom { return YES; }
%end

%end // iOS26

// ============================================================================
#pragma mark - C function hook: _CAMNightModeDurationForMode
// ============================================================================

extern void MSHookFunction(void *symbol, void *replace, void **result);

// IDA decompilation of _CAMNightModeDurationForMode:
//   mode 0 (Off)  → 0.0
//   mode 1 (Auto) → autoDuration (D0)
//   mode 2 (Max)  → maxDuration  (D1)
// We override mode 2 to return gMaxDuration.
static double (*orig_CAMNightModeDurationForMode)(long long mode, double autoDuration, double maxDuration);
static double hook_CAMNightModeDurationForMode(long long mode, double autoDuration, double maxDuration) {
    if (gTweakEnabled && mode == 2) {
        if (gNMEExtendedCaptureActive) {
            double remaining = NMERemainingTime();
            return remaining > 0 ? remaining : gMaxDuration;
        }
        return gMaxDuration;
    }
    return orig_CAMNightModeDurationForMode(mode, autoDuration, maxDuration);
}

// ============================================================================
#pragma mark - Constructor
// ============================================================================

%ctor {
    @autoreleasepool {
        loadPreferences();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, prefsChangedCallback,
            (__bridge CFStringRef)@"com.34306.nightmodeextender/prefsChanged",
            NULL, CFNotificationSuspensionBehaviorCoalesce
        );

        if (!gTweakEnabled) return;

        if (objc_getClass("CAMNightModeSlider")) {
            %init(iOS26);

            // Install non-ARC hooks for Swift struct parameters
            NMEInstallNoARCHooks();

            // Hook _CAMNightModeDurationForMode C function
            void *sym = dlsym(RTLD_DEFAULT, "CAMNightModeDurationForMode");
            if (sym) {
                MSHookFunction(sym, (void *)&hook_CAMNightModeDurationForMode,
                              (void **)&orig_CAMNightModeDurationForMode);
            }
        } else {
            %init(iOS15_18);
        }
    }
}
