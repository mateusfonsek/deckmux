
<!-- deckmux-install -->
## Instalação

Funciona em Mac com Apple Silicon ou Intel, com macOS 14 ou mais novo.

Pelo Homebrew: `brew install --cask mateusfonsek/tap/deckmux` (ou `brew upgrade --cask deckmux`, se já tiver).

Ou baixe o `Deckmux-@VERSION@-@ARCH@.dmg`, abra e arraste o Deckmux para Aplicativos.

O app não é assinado por um desenvolvedor registrado na Apple, então o macOS bloqueia a primeira abertura. Para liberar, uma vez só: abra o Deckmux, feche o aviso e vá em Ajustes do Sistema → Privacidade e Segurança → **Abrir Mesmo Assim**. Ou, no Terminal: `xattr -dr com.apple.quarantine /Applications/Deckmux.app`.

O `.zip` tem o mesmo app, para quem prefere (ou para gerenciadores de pacotes).

### SHA-256

```
@SHA256SUMS@
```
