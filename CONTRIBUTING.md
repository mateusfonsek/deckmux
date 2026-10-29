# Contribuir com o Deckmux

Obrigado pelo interesse. Issues e PRs são bem-vindos; para dúvidas, use as [Discussions](https://github.com/mateusfonsek/deckmux/discussions).

## Compilar e testar

Precisa do Xcode com Swift 6 (as Command Line Tools bastam) e macOS 14 ou mais novo.

```bash
scripts/build-app.sh debug          # monta build/app.noindex/Deckmux.app
swift test                          # testes da lógica (alvos Deckmux*)
scripts/package-release.sh --universal   # .dmg e .zip como na release, em dist/
```

Na primeira compilação, `scripts/ensure-ghosttykit.sh` baixa o GhosttyKit pré-compilado (versão fixada em `scripts/ghostty.env`) e confere o checksum.

### Testar sem mexer no Deckmux que você usa

O build de teste divide preferências com o app instalado, mas a sessão e o socket dos hooks podem ficar numa pasta à parte:

```bash
DECKMUX_SUPPORT_DIR=$PWD/build/ts build/app.noindex/Deckmux.app/Contents/MacOS/Deckmux
```

Use uma pasta de caminho curto: o socket dos hooks não passa de 104 caracteres. Para simular um Mac sem Claude Code nem uv, abra com o PATH mínimo e sem o seu `.zshrc`:

```bash
mkdir -p build/nozdot
open -n build/app.noindex/Deckmux.app --env DECKMUX_SUPPORT_DIR=$PWD/build/ts \
  --env ZDOTDIR=$PWD/build/nozdot --env PATH=/usr/bin:/bin:/usr/sbin:/sbin
```

## Onde fica o quê

- `Sources/Deckmux/`: o app (AppKit + SwiftUI). Sem testes automáticos; confira no build de teste.
- `Sources/Deckmux*` (alvos à parte, como `DeckmuxCalendar`, `DeckmuxTasks`, `DeckmuxShell`): lógica pura, só Foundation, com testes em `Tests/`. Regra que vale a pena: o que dá para testar sem tela vai para um desses alvos.
- `Sources/DeckmuxCLI/`: o comando `deckmux` (hooks do Claude Code e `deckmux task`).
- `Resources/bin/claude`: o wrapper que liga o Claude Code ao Deckmux em cada terminal.
- `Packages/`: Bonsplit e Highlightr copiados, com um `DECKMUX.md` dizendo o que foi mudado.

Textos da interface em português; comentários e nomes no código em inglês.

## Commits, PRs e versões

Os commits seguem [Conventional Commits](https://www.conventionalcommits.org/pt-br/): `feat:` para novidade, `fix:` para correção, e `docs:`, `refactor:`, `test:`, `ci:` ou `chore:` para o resto. Um `!` depois do tipo (`feat!:`) marca uma mudança que quebra compatibilidade.

Os PRs entram por squash, então o **título do PR** é que precisa seguir o padrão (o CI confere). O CI também compila o app (Apple Silicon + Intel) e roda os testes em todo PR.

As versões seguem [SemVer](https://semver.org/lang/pt-BR/) e saem pelo [release-please](https://github.com/googleapis/release-please):

1. A cada push na `main`, o release-please atualiza um PR de release com a próxima versão (`feat` sobe o minor, `fix` sobe o patch) e o `CHANGELOG.md`.
2. Ao mergear esse PR, a tag `vX.Y.Z` e a Release são criadas; o CI anexa o `.dmg`, o `.zip` e o `SHA256SUMS`, e atualiza o cask do [Homebrew](https://github.com/mateusfonsek/homebrew-tap).
