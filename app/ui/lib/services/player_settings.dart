/// The few player settings the mpv layer reads. Plezy kept these in a large
/// settings service; Couchmates uses fixed values until there's a setting
/// screen for them.
abstract final class PlayerSettings {
  /// Android libass overlay render scale (fraction of the surface
  /// resolution). Below 1 trades subtitle sharpness for speed on slow GPUs.
  static double subtitleRenderScale = 1.0;
}
