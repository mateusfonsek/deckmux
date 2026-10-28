# Highlightr (vendored)

Copy of [raspu/Highlightr](https://github.com/raspu/Highlightr) 2.3.0
(`05e7fcc63b33925cd0c1faaa205cdd5681e7bbef`), MIT; highlight.js 11.11.1
(BSD-3-Clause, `src/assets/highlighter/LICENSE`). The example app, the GIFs and
every theme except `github` and `github-dark` were left out. `github.min.css`
is highlight.js 11.11.1's (GitHub's light colors, the pair of `github-dark`):
Highlightr 2.3.0 shipped the base16 "Github" theme under that name, whose
`#e8e8e8` tags were nearly invisible on white.

Deckmux changes (marked `DECKMUX` in the code):
- Resource bundle: `HighlightrResources` looks for `Highlightr_Highlightr.bundle`
  in the app's `Contents/Resources` (where `scripts/build-app.sh` copies the
  SwiftPM bundles). SwiftPM's `Bundle.module` only looks next to the `.app`
  (code signing allows nothing there) and in `.build`, and calls `fatalError`
  when both miss: the installed app crashed on the first colored file.
- Default theme on init: `github` (the only light theme kept) instead of `pojoaque`.
- Theme parser: compound selectors (`.hljs-title.function_`, highlight.js 11)
  are kept and matched against spans with several classes; other descendant
  selectors (`.hljs-meta .hljs-keyword`) are skipped instead of styling both
  classes everywhere; rules apply in source order. Before this, `github-dark`
  lost its keyword and title colors.
