#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/CAMetalLayer.h>
#include "ghostty.h"
#include <stdio.h>
#include <string.h>

static size_t received_bytes;
static size_t resize_count;
static void wakeup(void *data) {}
static bool action(ghostty_app_t app, ghostty_target_s target, ghostty_action_s value) { return false; }
static bool read_clipboard(void *data, ghostty_clipboard_e clipboard, void *state) { return false; }
static void confirm_clipboard(void *data, const char *text, void *state, ghostty_clipboard_request_e request) {}
static void write_clipboard(void *data, ghostty_clipboard_e clipboard, const ghostty_clipboard_content_s *content, size_t count, bool confirm) {}
static void close_surface(void *data, bool alive) {}
static void receive(void *data, const uint8_t *bytes, size_t length) { received_bytes += length; }
static void resize(void *data, uint16_t columns, uint16_t rows, uint32_t width, uint32_t height) { resize_count++; }

static void pump(ghostty_app_t app) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.05];
    do {
        ghostty_app_tick(app);
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    } while ([deadline timeIntervalSinceNow] > 0);
}

static bool has_output(ghostty_surface_t surface) {
    ghostty_selection_s selection = {
        .top_left = {.tag = GHOSTTY_POINT_VIEWPORT, .coord = GHOSTTY_POINT_COORD_TOP_LEFT},
        .bottom_right = {.tag = GHOSTTY_POINT_VIEWPORT, .coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT},
    };
    ghostty_text_s text = {0};
    if (!ghostty_surface_read_text(surface, selection, &text)) return false;
    NSString *output = [[NSString alloc] initWithBytes:text.text length:text.text_len encoding:NSUTF8StringEncoding];
    bool found = [output containsString:@"lifecycle probe"];
    ghostty_surface_free_text(surface, &text);
    return found;
}

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (ghostty_init(0, NULL) != GHOSTTY_SUCCESS) return 1;
        ghostty_config_t config = ghostty_config_new();
        if (!config) return 2;
        ghostty_config_finalize(config);
        ghostty_runtime_config_s runtime = {
            .wakeup_cb = wakeup, .action_cb = action,
            .read_clipboard_cb = read_clipboard, .confirm_read_clipboard_cb = confirm_clipboard,
            .write_clipboard_cb = write_clipboard, .close_surface_cb = close_surface,
        };
        ghostty_app_t app = ghostty_app_new(&runtime, config);
        if (!app) return 3;
        const char *compositions[] = {"😀", "é", "👩🏽‍💻", "🇨🇳", "中文"};
        for (int cycle = 0; cycle < 3; cycle++) {
            NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
            view.wantsLayer = YES;
            view.layer = [CAMetalLayer layer];
            ghostty_surface_config_s options = ghostty_surface_config_new();
            options.platform_tag = GHOSTTY_PLATFORM_MACOS;
            options.platform.macos.nsview = (__bridge void *)view;
            options.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED;
            options.receive_buffer = receive;
            options.receive_resize = resize;
            options.scale_factor = 1;
            options.font_size = 14;
            ghostty_surface_t surface = ghostty_surface_new(app, &options);
            if (!surface) return 4;
            ghostty_surface_set_size(surface, 640, 480);
            ghostty_surface_set_focus(surface, true);
            const char *output = "lifecycle probe\r\n";
            ghostty_surface_write_buffer(surface, (const uint8_t *)output, strlen(output));
            pump(app);
            if (!has_output(surface)) return 5;
            size_t before = received_bytes;
            for (size_t sample = 0; sample < sizeof(compositions) / sizeof(compositions[0]); sample++) {
                ghostty_surface_preedit(surface, compositions[sample], strlen(compositions[sample]));
                pump(app);
                ghostty_surface_draw(surface);
                if (!view.layer.contents || CFGetTypeID((__bridge CFTypeRef)view.layer.contents) != IOSurfaceGetTypeID()) return 6;
            }
            ghostty_surface_preedit(surface, NULL, 0);
            if (received_bytes != before) return 7;
            ghostty_surface_set_occlusion(surface, false);
            ghostty_surface_set_occlusion(surface, true);
            ghostty_surface_set_size(surface, 8, 32);
            pump(app);
            ghostty_surface_draw(surface);
            if (ghostty_surface_size(surface).columns != 1) return 8;
            ghostty_surface_text(surface, "x", 1);
            pump(app);
            if (received_bytes != before + 1) return 9;
            ghostty_surface_free(surface);
            pump(app);
        }
        if (!resize_count) return 10;
        ghostty_app_free(app);
        ghostty_config_free(config);
        puts("PASS Ghostty lifecycle, Unicode, Metal presentation and teardown");
    }
    return 0;
}
