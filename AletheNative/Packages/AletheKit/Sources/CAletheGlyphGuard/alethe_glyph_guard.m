// macOS 27's SwiftUI can ask CoreUI for an SF Symbol at a 0x0 target size mid-animation (a toolbar
// item held in a hidden host, sidebar rows expanding from zero height, ...). CoreUI asserts
// `targetSizeInPoints.width>0 && targetSizeInPoints.height>0`, the NSInternalInconsistencyException
// reaches AppKit's layout pass and the app crashes. -[CUINamedVectorGlyph image] is the last
// Objective-C method above that assertion (the rasterizer itself is an objc_direct method), so the
// guard wraps it: a glyph with no size returns no image, and any assertion from the rasterizer is
// caught right there, before it can unwind through Swift frames. Callers already treat a NULL image
// as nothing to draw.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "alethe_glyph_guard.h"

typedef CGImageRef (*AletheGlyphImageIMP)(id, SEL);
static AletheGlyphImageIMP alethe_original_image;

static double alethe_double_property(id glyph, SEL selector) {
    if (![glyph respondsToSelector:selector]) return 1;
    return ((double (*)(id, SEL))objc_msgSend)(glyph, selector);
}

static CGImageRef alethe_guarded_image(id self, SEL _cmd) {
    if (alethe_double_property(self, @selector(pointSize)) <= 0
        || alethe_double_property(self, @selector(scale)) <= 0) {
        return NULL;
    }
    @try {
        return alethe_original_image(self, _cmd);
    } @catch (NSException *exception) {
        if ([exception.name isEqualToString:NSInternalInconsistencyException]) return NULL;
        @throw;
    }
}

void alethe_install_vector_glyph_guard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class glyph = NSClassFromString(@"CUINamedVectorGlyph");
        Method image = glyph ? class_getInstanceMethod(glyph, @selector(image)) : NULL;
        if (image == NULL) return;
        alethe_original_image = (AletheGlyphImageIMP)method_setImplementation(image, (IMP)alethe_guarded_image);
    });
}
