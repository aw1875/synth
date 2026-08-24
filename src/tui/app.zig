//! The app as a widget: the one place that knows about every part of it.
//!
//! `model.zig` holds the state, `keys.zig` routes input, `render.zig` draws.
//! Each of those depends only on what it needs; this stitches them into the
//! `vxfw.Widget` the runtime drives, so none of them has to import the others.

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const keys = @import("keys.zig");
const Model = @import("model.zig");
const render = @import("render.zig");

/// Connect the pieces the Model owns. Call once, before the first frame.
pub fn wire(model: *Model) !void {
    try model.wire();
    model.input.userdata = model;
    model.input.onSubmit = keys.handleSubmit;
    model.vtable = widget(model);
    model.plain_vtable = plainWidget(model);
}

/// The app, ready for `vxfw.App.run`.
pub fn widget(model: *Model) vxfw.Widget {
    return .{
        .userdata = model,
        .captureHandler = keys.typeErasedCaptureHandler,
        .eventHandler = keys.typeErasedEventHandler,
        .drawFn = render.typeErasedDrawFn,
    };
}

/// The same app without the handlers: what a surface drawn by something else
/// is attributed to, so a click on it does not re-enter the router.
pub fn plainWidget(model: *Model) vxfw.Widget {
    return .{
        .userdata = model,
        .drawFn = render.typeErasedDrawFn,
    };
}
