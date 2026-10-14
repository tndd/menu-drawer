#include "Capture.h"
// 画面外へ収納したステータス項目は ScreenCaptureKit で取得できないため、
// macOS 15 にも残る従来の公開 API をこの境界に隔離する。
CGImageRef MDImageForWindow(CGWindowID windowID) {
    return CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow,
        windowID, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
}
