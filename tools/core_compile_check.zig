const core = @import("zigui_core");

/// Build-only consumer root. These references force the platform-free module
/// through semantic analysis without importing a native platform, GPU backend,
/// font implementation, codec, standard control, inspector, or tracer.
pub fn main() void {
    _ = core.Error;
    _ = core.NodeStore;
    _ = core.NodeSpec;
    _ = core.layout_engine.Engine.layout;
    _ = core.focus.Manager.move;
    _ = core.custom.Node;
    _ = core.text.Backend.shape;
    _ = core.scene.Builder.finish;
    _ = core.render.Renderer.submit;
    _ = core.render_extension.Registry.register;
}
