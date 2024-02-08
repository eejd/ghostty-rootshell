#import "PlusDarkerBlendingModeLayer.h"

@implementation PlusDarkerBlendingModeLayer

// A private compositing filter ("plus darker") that is used in titlebar
// tab bars to create the effect of recessed, unselected tabs.
- (id)compositingFilter { return @"plusD"; }

@end
