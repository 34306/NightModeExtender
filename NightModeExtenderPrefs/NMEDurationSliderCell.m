#import "NMEDurationSliderCell.h"

// Marked positions on the slider (seconds → display label)
static const double kMarks[] = { 10, 30, 60, 120, 180, 300 };
static NSString *const kMarkLabels[] = { @"10s", @"30s", @"1m", @"2m", @"3m", @"5m" };
static const int kMarkCount = 6;

@implementation NMEDurationSliderCell {
    UISlider *_slider;
    UILabel  *_valueLabel;
    UIView   *_marksContainer;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)identifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        // -- Value label (large, centered) --
        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:32 weight:UIFontWeightBold];
        _valueLabel.textAlignment = NSTextAlignmentCenter;
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_valueLabel];

        // -- Slider --
        _slider = [[UISlider alloc] init];
        _slider.minimumValue = 10;
        _slider.maximumValue = 300;
        _slider.minimumTrackTintColor = [UIColor systemYellowColor];
        _slider.translatesAutoresizingMaskIntoConstraints = NO;
        [_slider addTarget:self action:@selector(_sliderMoved:)
          forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(_sliderDone:)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [self.contentView addSubview:_slider];

        // -- Marks container --
        _marksContainer = [[UIView alloc] init];
        _marksContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_marksContainer];

        // Layout
        [NSLayoutConstraint activateConstraints:@[
            [_valueLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [_valueLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],

            [_slider.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:14],
            [_slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [_slider.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],

            [_marksContainer.topAnchor constraintEqualToAnchor:_slider.bottomAnchor constant:6],
            [_marksContainer.leadingAnchor constraintEqualToAnchor:_slider.leadingAnchor],
            [_marksContainer.trailingAnchor constraintEqualToAnchor:_slider.trailingAnchor],
            [_marksContainer.heightAnchor constraintEqualToConstant:20],
            [_marksContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        ]];

        // Read saved value
        double saved = 300;
        id pref = [specifier performGetter];
        if (pref) saved = [pref doubleValue];
        if (saved < 10) saved = 10;
        if (saved > 300) saved = 300;
        _slider.value = saved;
        [self _updateLabel:saved];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self _layoutMarks];
}

// ---- Mark tick labels ----

- (void)_layoutMarks {
    // Remove old marks
    for (UIView *v in _marksContainer.subviews) [v removeFromSuperview];

    CGFloat w = _marksContainer.bounds.size.width;
    if (w <= 0) return;

    CGFloat minVal = _slider.minimumValue;
    CGFloat maxVal = _slider.maximumValue;
    CGFloat range  = maxVal - minVal;

    for (int i = 0; i < kMarkCount; i++) {
        CGFloat frac = (kMarks[i] - minVal) / range;
        CGFloat x = frac * w;

        // Tick line
        UIView *tick = [[UIView alloc] initWithFrame:CGRectMake(x - 0.5, 0, 1, 6)];
        tick.backgroundColor = [UIColor tertiaryLabelColor];
        [_marksContainer addSubview:tick];

        // Label
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = kMarkLabels[i];
        lbl.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        lbl.textColor = [UIColor secondaryLabelColor];
        lbl.textAlignment = NSTextAlignmentCenter;
        [lbl sizeToFit];
        CGFloat lx = x - lbl.frame.size.width / 2;
        // Clamp to bounds
        if (lx < 0) lx = 0;
        if (lx + lbl.frame.size.width > w) lx = w - lbl.frame.size.width;
        lbl.frame = CGRectMake(lx, 7, lbl.frame.size.width, lbl.frame.size.height);
        [_marksContainer addSubview:lbl];
    }
}

// ---- Slider events ----

- (void)_sliderMoved:(UISlider *)slider {
    double snapped = [self _snap:slider.value];
    [self _updateLabel:snapped];
}

- (void)_sliderDone:(UISlider *)slider {
    double snapped = [self _snap:slider.value];
    [slider setValue:snapped animated:YES];
    [self _updateLabel:snapped];

    // Save
    [[self specifier] performSetterWithValue:@(snapped)];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.34306.nightmodeextender/prefsChanged"),
        NULL, NULL, YES
    );
}

// Snap to nearest mark if close, otherwise nearest 10s
- (double)_snap:(double)raw {
    // Check proximity to marks (within 8 seconds)
    for (int i = 0; i < kMarkCount; i++) {
        if (fabs(raw - kMarks[i]) < 8.0) return kMarks[i];
    }
    double snapped = round(raw / 10.0) * 10.0;
    if (snapped < 10) snapped = 10;
    if (snapped > 300) snapped = 300;
    return snapped;
}

// ---- Display ----

- (void)_updateLabel:(double)seconds {
    int s = (int)seconds;
    if (s >= 60) {
        int m = s / 60;
        int r = s % 60;
        _valueLabel.text = r == 0
            ? [NSString stringWithFormat:@"%d min", m]
            : [NSString stringWithFormat:@"%d min %d sec", m, r];
    } else {
        _valueLabel.text = [NSString stringWithFormat:@"%d sec", s];
    }
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    id val = [specifier performGetter];
    if (val) {
        double d = [val doubleValue];
        _slider.value = d;
        [self _updateLabel:d];
    }
}

- (void)setCellEnabled:(BOOL)enabled {
    [super setCellEnabled:enabled];
    _slider.enabled = enabled;
    _slider.alpha = enabled ? 1.0 : 0.5;
    _valueLabel.alpha = enabled ? 1.0 : 0.4;
}

@end
