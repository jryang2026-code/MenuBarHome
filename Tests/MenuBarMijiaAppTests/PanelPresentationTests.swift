import Testing

/// Panel windows and renderers share AppKit state, LayoutUIState and standard view preferences.
/// A serialized parent prevents the suites from interleaving across their asynchronous fixtures.
@Suite(.serialized)
struct PanelPresentationTests {}
