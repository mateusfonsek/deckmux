# Segurança

## Como reportar

Não abra uma issue pública para uma falha de segurança. Reporte em privado pela aba **Security** do repositório: [Report a vulnerability](https://github.com/mateusfonsek/deckmux/security/advisories/new).

Diga o que encontrou, como reproduzir e a versão do Deckmux. A resposta vem em até 7 dias; a correção sai numa versão nova e o crédito é seu, se quiser.

## Versões cobertas

Só a versão mais recente recebe correções. Atualize com `brew upgrade --cask deckmux` ou pela [última Release](https://github.com/mateusfonsek/deckmux/releases/latest).

## O que interessa

O Deckmux lida com credenciais (o token do Claude Code no Keychain, os tokens do Google em `~/.config/google-workspace-mcp`) e roda comandos nos seus terminais. Falhas que exponham essas credenciais, que deixem outro processo mandar comandos ao Deckmux (o socket dos hooks) ou que escrevam fora das pastas que o app declara são o tipo de problema que importa aqui.
