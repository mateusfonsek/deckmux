Código do app macOS do Ghostty (MIT, ver LICENSE), copiado do fork
`manaflow-ai/ghostty` no commit `cb1ef7091cdef0b581ee2cbd83742b653253523e`,
pasta `macos/Sources/{Ghostty,Helpers,Features/Secure Input}`.
As mudanças do Deckmux trocam as referências ao app do Ghostty
(`AppDelegate`, `BaseTerminalController`, `SplitTree`) pelo host do Deckmux.

Mudanças em relação ao original:
- `BaseTerminalController` → protocolo `GhosttyTerminalHost` (`App/GhosttyHost.swift`), nas ações de split, título, opacidade e foco.
- Removido o uso de `SplitTree`, `SplitView`, `TerminalWindow`, `HiddenTitlebarTerminalWindow` e `Dock` (não fazem parte do Deckmux).
- O inspetor do terminal aparece empilhado (`VSplitView`) em vez do `SplitView` do Ghostty.
- Removido o item "Change Tab Title..." do menu de contexto.
- `Features/QuickTerminal/*` só para os tipos de configuração.
- `goto_tab` e `move_tab` consultam `GhosttyTerminalHost.hasMultipleTabs` em vez das abas nativas do macOS.
- `Ghostty.Config.loadConfig` carrega `DeckmuxGhosttyDefaults` antes dos arquivos de config do usuário.
- Sem o grab handle (três pontinhos) de arrastar splits: no Deckmux quem arrasta são as abas do Bonsplit.
