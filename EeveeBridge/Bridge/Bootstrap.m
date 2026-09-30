#import <Foundation/Foundation.h>
#import <dlfcn.h>

extern void LyricsDriveBridgeStart(void);

__attribute__((constructor))
static void LyricsDriveBridgeBootstrap(void) {
    @autoreleasepool {
        NSString *frameworks = [[NSBundle mainBundle] privateFrameworksPath];
        NSString *original = [frameworks stringByAppendingPathComponent:@"zxPluginsInjectOriginal.dylib"];
        dlopen(original.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        LyricsDriveBridgeStart();
    }
}
