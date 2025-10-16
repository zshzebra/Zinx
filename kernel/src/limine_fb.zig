const limine = @import("limine");
const fb = @import("framebuffer.zig");
const Framebuffer = fb.Framebuffer;
const FramebufferInfo = fb.FramebufferInfo;
const MAX_FRAMEBUFFERS = fb.MAX_FRAMEBUFFERS;

pub export var framebuffer_request: limine.FramebufferRequest = .{};

pub fn initFramebuffers() ?FramebufferInfo {
    const response = framebuffer_request.response orelse return null;
    if (response.framebuffer_count < 1) return null;

    var info = FramebufferInfo{ .count = @min(response.framebuffer_count, MAX_FRAMEBUFFERS), .buffers = [_]?Framebuffer{null} ** MAX_FRAMEBUFFERS };

    var i: usize = 0;
    while (i < info.count) : (i += 1) {
        const framebuffer = response.getFramebuffers()[i];
        info.buffers[i] = Framebuffer.init(@ptrCast(framebuffer.address), framebuffer.width, framebuffer.height, framebuffer.pitch, framebuffer.bpp, .XRGB);
    }

    return info;
}
