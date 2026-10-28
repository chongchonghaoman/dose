#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

#define LT_EDR_API FOUNDATION_EXPORT __attribute__((visibility("default")))

/// Binary-only EDR component. See the accompanying proprietary license.
LT_EDR_API double LTEDRBrightness(void);
LT_EDR_API double LTEDRHeadroom(double available);
LT_EDR_API double LTEDRPanelLevel(double ordinaryLevel);
LT_EDR_API CIImage *LTEDRApply(CIImage *image, double availableHeadroom);
LT_EDR_API CIImage *LTEDRCompose(CIImage *image, double lampGain, double exposureStops, double availableHeadroom);
/// Used by packaging and regression checks to detect a missing kernel resource.
LT_EDR_API BOOL LTEDRIsReady(void);

NS_ASSUME_NONNULL_END
