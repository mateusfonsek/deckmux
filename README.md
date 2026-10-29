# Deckmux

Centro de comando para macOS, feito para quem passa o dia no terminal com o [Claude Code](https://claude.com/claude-code). Terminais no nível do [cmux](https://github.com/manaflow-ai/cmux) (libghostty + Bonsplit), organizados por workspace, com a agenda, as tarefas e o estado de cada sessão do Claude à vista.

A interface é em português.

## O que tem

- **Terminais de verdade:** libghostty, com abas e splits (Bonsplit). A sessão volta ao reabrir o app: layout, pastas, scrollback e a conversa do Claude Code que rodava em cada terminal.
- **Workspaces:** cada pasta com um `.workspace.json` vira um grupo na barra lateral, com nome e cor. A cor aparece na barra lateral, nas abas, nas reuniões e nas tarefas.
- **Claude Code integrado:** por hooks, o Deckmux sabe quando o Claude está trabalhando, terminou ou espera você, e mostra isso no item, na aba, no menu e em notificações.
- **Hoje:** reuniões do dia numa linha do tempo, com o botão para entrar no Meet, Zoom ou Teams, e um quadro de tarefas. O Claude também mexe no quadro, pelo comando `deckmux task`, quando você pede.
- **Configuração do workspace:** `CLAUDE.md`, tema e servidores MCP (Google Calendar + Drive, Slack, ClickUp ou qualquer servidor stdio/http), com revisão do que muda antes de gravar.
- **Aba de código:** árvore de arquivos, alterações do git e diff lado a lado, sem sair do app.
- **Gerenciador de tarefas:** CPU e memória por janela, workspace, item e terminal.
- **Janelinha:** painel flutuante opcional com as sessões do Claude, os subagents e o uso da conta.
- **Chats personalizados:** nome próprio e uma etiqueta (cor + ícone) por item, pelo botão direito.

## Instalar

Funciona em Mac com Apple Silicon ou Intel, com macOS 14 ou mais novo.

Pelo [Homebrew](https://brew.sh):

```bash
brew install --cask mateusfonsek/tap/deckmux
```

Atualizar: `brew upgrade --cask deckmux`. O cask libera o app no macOS durante a instalação (tira a marca de quarentena), então ele abre direto.

Ou baixe o `Deckmux-<versão>-universal.dmg` da [última versão](https://github.com/mateusfonsek/deckmux/releases/latest), abra e arraste o Deckmux para Aplicativos (há também um `.zip` com o mesmo app).

O app não é assinado por um desenvolvedor registrado na Apple, então, baixado pelo navegador, o macOS bloqueia a primeira abertura ("não foi possível verificar…"). Para liberar, uma vez só:

1. Abra o Deckmux e feche o aviso.
2. Vá em Ajustes do Sistema → Privacidade e Segurança, desça até "Deckmux foi bloqueado" e clique em **Abrir Mesmo Assim**.

Ou, no Terminal: `xattr -dr com.apple.quarantine /Applications/Deckmux.app`.

Na primeira abertura, o Deckmux pede a pasta onde ficam os seus workspaces (cada subpasta com um `.workspace.json` vira um grupo na barra lateral; dá para criar pela aba Workspaces) e abre com um terminal e a tela Hoje. A integração com o Claude Code funciona sem configurar nada e não altera o seu `~/.claude/settings.json`.

## Agenda

As reuniões vêm do Calendário do macOS: qualquer conta que estiver no Mac (iCloud, Google, Outlook…) aparece, basta permitir o acesso aos calendários. Na primeira visita à tela Hoje, um guia mostra como:

1. **Permitir o acesso aos calendários.**
2. **Google no Mac (opcional):** Ajustes do Sistema → Contas de Internet → Adicionar Conta → Google, com Calendários ligado.
3. **Google no Claude (opcional):** adicionar o MCP do Google a um workspace (Agenda + Drive para o Claude), com um cliente OAuth do Google Cloud. Um workspace com a conta Google conectada também passa a ler a agenda dessa conta direto pela API do Google.

Depois, o guia volta pelo ícone **?** ao lado de Hoje.

Para usar com o Claude Code, ele precisa estar no `PATH`. Para o MCP do Google, o [uv](https://docs.astral.sh/uv/) (`uvx`).

## Compilar a partir do código

Precisa do Xcode com Swift 6 (as Command Line Tools bastam).

```bash
scripts/build-app.sh release --open   # monta build/app.noindex/Deckmux.app e abre
```

Na primeira compilação, `scripts/ensure-ghosttykit.sh` baixa o GhosttyKit pré-compilado (fork do cmux, versão fixada em `scripts/ghostty.env`) e confere o checksum.

Para instalar, feche o Deckmux e copie `build/app.noindex/Deckmux.app` para `/Applications`.

Testes: `swift test`.

Para gerar o `.dmg` e o `.zip` como na release: `scripts/package-release.sh --universal` (saem em `dist/`, com `SHA256SUMS`). Sem `--universal`, o build sai só para a arquitetura do seu Mac, mais rápido.

O app é assinado ad-hoc, tanto o da release quanto o compilado. O macOS liga as permissões (Acessibilidade, Gravação de Tela) ao binário, então pode ser preciso concedê-las de novo depois de instalar uma versão nova.

## Privacidade

O Deckmux não tem conta, servidor nem telemetria. O que ele lê e para onde vai:

- **Calendário do Mac:** só com a sua permissão, para mostrar as reuniões. Fica no Mac.
- **Google (opcional):** se você conectar uma conta num workspace, o login acontece no navegador, direto com o Google, e o token fica em `~/.config/google-workspace-mcp/<workspace>/`, com permissão 600. O app usa esse token para ler a agenda na API do Google, e o MCP do Google (do Claude Code) usa o mesmo token.
- **Uso da conta do Claude (opcional):** com a Janelinha ligada, o app lê o token do Claude Code (o arquivo dele ou o item "Claude Code-credentials" do Keychain) para consultar o uso da conta na API da Anthropic. O token não é gravado em outro lugar; só os números de uso ficam guardados, na pasta da sessão.
- **Sessão:** layout, pastas e o histórico dos terminais (até 4.000 linhas por terminal) ficam em `~/Library/Application Support/Deckmux`, no seu Mac.
- **Configuração dos workspaces:** o app só grava o que você confirma na tela de revisão, que mostra cada arquivo antes: os do workspace (`CLAUDE.md`, `.mcp.json`, `.workspace.json`) e, quando a mudança pede, os do Claude Code (`~/.claude/settings.json` para pré-aprovar MCPs, `~/.claude.json`, `~/.claude/workspace.md`, temas em `~/.claude/themes`).
- **Integração com o Claude Code nos terminais:** os hooks entram só no lançamento de cada `claude`, por `--settings`; nada é gravado na sua configuração.

## Contribuir

Veja o [CONTRIBUTING.md](CONTRIBUTING.md): compilar, testar sem mexer no app que você usa, padrão de commits e como as versões saem. Dúvidas vão para as [Discussions](https://github.com/mateusfonsek/deckmux/discussions); falhas de segurança, pelo [SECURITY.md](SECURITY.md).

## Licença

[GPL-3.0](LICENSE). Contém código adaptado do cmux (GPL-3.0-or-later, © Manaflow, Inc.) e do app macOS do Ghostty (MIT). O Bonsplit e o Highlightr estão em `Packages/`, cada um com a própria licença e um `DECKMUX.md` com o que foi mudado.
