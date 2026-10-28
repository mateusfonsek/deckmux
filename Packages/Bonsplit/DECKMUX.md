# Bonsplit (vendored)

Copy of [manaflow-ai/bonsplit](https://github.com/manaflow-ai/bonsplit) at
`d67d1b114fd20edba7a19f76cc39e35bde43c2d8` (the revision cmux pins), MIT.
Tests and the example app were left out.

Deckmux changes:
- Per-tab tint (`Tab.tintHex`, `createTab(tintHex:)`, `updateTab(tintHex:)`):
  colors the tab icon, the active indicator and a light background, so each
  tab shows its workspace's color.
- Tab bar background follows light/dark (`TabBarLayerBackedColor`): the color
  is kept and its `cgColor` resolved again in `viewDidChangeEffectiveAppearance`,
  and the unfocused pane's 95% alpha uses `bonsplitScalingAlpha(by:)` (a
  dynamic color) instead of `withAlphaComponent`, which froze
  `windowBackgroundColor` in whatever appearance was current. Before, a tab bar
  kept the colors of the appearance it was created in (black in light mode
  after a split, light after switching to dark), terminal-only layouts too.
