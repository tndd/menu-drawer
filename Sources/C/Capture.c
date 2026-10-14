#include "Capture.h"
// 画面外へ収納したステータスウィンドウも取得するため、従来のウィンドウ単位APIを使用する。
CGImageRef MDWindowImage(CGWindowID window) {
    return CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, window,
        kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
}
CGImageRef MDBarImage(CGRect rect) {
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!info) return NULL;
    CFMutableArrayRef windows = CFArrayCreateMutable(NULL, 0, NULL);
    for (CFIndex i = 0; i < CFArrayGetCount(info); i++) {
        CFDictionaryRef row = CFArrayGetValueAtIndex(info, i);
        CFStringRef owner = CFDictionaryGetValue(row, kCGWindowOwnerName);
        // 拡大ポインターなどの補助表示を固定画像へ混ぜない。
        if (owner && CFEqual(owner, CFSTR("AccessibilityVisualsAgent"))) continue;
        CFNumberRef number = CFDictionaryGetValue(row, kCGWindowNumber);
        int32_t window = 0;
        if (number && CFNumberGetValue(number, kCFNumberSInt32Type, &window))
            CFArrayAppendValue(windows, (void *)(uintptr_t)window);
    }
    CGImageRef image = CGWindowListCreateImageFromArray(rect, windows,
        kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
    CFRelease(windows);
    CFRelease(info);
    return image;
}
