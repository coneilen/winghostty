//! Presentation boundary for the embeddable Win32 renderer.
//!
//! Keeping the swap boundary separate from WGL context construction makes it
//! explicit that only this module presents the child surface. The context
//! module owns device handles; callers never need to release HDC/HGLRC.

const Context = @import("win32_context.zig");

pub const Error = Context.Error;
pub const RenderState = Context.RenderState;

pub fn render(context: *Context.Context, state: RenderState) Error!void {
    return context.render(state);
}

pub fn present(context: *Context.Context) Error!void {
    return context.present();
}
