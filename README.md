# Deckmux

Centro de comando para macOS, feito para quem passa o dia no terminal com o [Claude Code](https://claude.com/claude-code). Terminais no nível do [cmux](https://github.com/manaflow-ai/cmux) (libghostty + Bonsplit), organizados por workspace, com a agenda, as tarefas e o estado de cada sessão do Claude à vista.

A interface é em português.

## O que tem

- **Terminais de verdade:** libghostty, com abas e splits (Bonsplit). A sessão volta ao reabrir o app: layout, pastas, scrollback e a conversa do Claude Code que rodava em cada terminal.
- **Workspaces:** cada pasta com um `.workspace.json` vira um grupo na barra lateral, com nome e cor. A cor aparece na barra lateral, nas abas, nas reuniões e nas tarefas.
- **Claude Code integrado:** por hooks, o Deckmux sabe quando o Claude está trabalhando, terminou ou espera você, e mostra isso no item, na aba, no menu e em notificações.
- **Hoje:** reuniões do dia (Google Calendar) numa linha do tempo e um quadro de tarefas. O Claude também mexe no quadro, pelo comando `deckmux task`, quando você pede.
- **Configuração do workspace:** `CLAUDE.md`, tema e servidores MCP (Google Calendar + Drive, Slack, ClickUp ou qualquer servidor stdio/http), com revisão do que muda antes de gravar.
- **Aba de código:** árvore de arquivos, alterações do git e diff lado a lado, sem sair do app.
- **Gerenciador de tarefas:** CPU e memória por janela, workspace, item e terminal.
- **Janelinha:** painel flutuante opcional com as sessões do Claude, os subagents e o uso da conta.
- **Chats personalizados:** nome próprio e uma etiqueta (cor + ícone) por item, pelo botão direito.

## Requisitos

- macOS 14 ou mais novo.
- Xcode com Swift 6 (as Command Line Tools bastam).
- [Claude Code](https://claude.com/claude-code) no `PATH`. Para o MCP do Google, o [uv](https://docs.astral.sh/uv/) (`uvx`).

## Compilar e instalar

```bash
scripts/build-app.sh release --open   # monta build/app.noindex/Deckmux.app e abre
```

Na primeira compilação, `scripts/ensure-ghosttykit.sh` baixa o GhosttyKit pré-compilado (fork do cmux, versão fixada em `scripts/ghostty.env`) e confere o checksum.

Para instalar, feche o Deckmux e copie `build/app.noindex/Deckmux.app` para `/Applications`.

Testes: `swift test`.

O app é assinado ad-hoc. O macOS liga as permissões (Acessibilidade, Gravação de Tela) ao binário, então pode ser preciso concedê-las de novo depois de instalar uma versão nova.

## Licença

[GPL-3.0](LICENSE). Contém código adaptado do cmux (GPL-3.0-or-later, © Manaflow, Inc.) e do app macOS do Ghostty (MIT). O Bonsplit e o Highlightr estão em `Packages/`, cada um com a própria licença e um `DECKMUX.md` com o que foi mudado.
