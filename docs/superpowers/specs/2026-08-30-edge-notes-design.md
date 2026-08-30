# edge-notes — Design

Data: 2026-08-30
Autor: Luis Davel (com Claude)
Status: aprovado em conversa; aguardando revisão final do spec

## Visão

App macOS nativo (Swift) de sticky notes nas bordas da tela, inspirado em
holdmynotes.app. Borda **direita**: deck de notas avulsas em Markdown. Borda
**esquerda** (fase 2): deck integrado ao Day (app de tarefas próprio do Luis),
via API HTTP. Sem ícone no Dock, sem roubar foco, funciona sobre apps em
fullscreen.

Repo: `LuisDavel/edge-notes` (público).

## Fases

- **Fase 1 (v1):** deck direito (notas markdown) + janela biblioteca "All Notes".
- **Fase 2:** deck esquerdo consumindo a API do Day + ação "enviar nota pro Day".

## 1. Comportamento de janela

- Processo `LSUIElement` (sem Dock). Item no menu bar: sair, configurações,
  abrir biblioteca.
- Cada borda usa um `NSPanel` com `.nonactivatingPanel`, `.canJoinAllSpaces`,
  `.fullScreenAuxiliary`, window level acima de janelas normais. Aparece sobre
  fullscreen; não rouba foco até o usuário clicar num campo de texto.
- **Repouso:** pill de 12pt encostada na borda, um traço colorido por nota ativa.
- **Hover:** notas fazem "fan" em cascata descendo a borda, stagger de 45ms,
  cada nota mostra aba vertical com o rótulo (título) e sua cor.
- **Clique na aba:** a nota desliza pra fora do deck em tamanho cheio, editável
  inline. Autosave 250ms após parar de digitar.
- Botão `+` no pé do deck cria nota nova já aberta pra edição.
- Fechar a nota (clique fora ou Esc) recolhe de volta pro deck.

## 2. Modelo de dados

- Notas em `~/Library/Application Support/EdgeNotes/notes/<uuid>.md`
  (pasta configurável em fase posterior).
- Frontmatter YAML por nota:
  - `title` (string)
  - `color` (slug de paleta fixa: blue, green, yellow, purple, pink, orange)
  - `status`: `active` | `archived`
  - `createdAt`, `updatedAt` (ISO 8601)
- Corpo do arquivo = markdown livre.
- Core observa a pasta via FSEvents: edições externas ao .md refletem no deck.
- Deck mostra somente `active`, ordenadas por `updatedAt` desc. Arquivadas só
  aparecem na biblioteca.
- Deletar = remover arquivo (com confirmação na UI).

## 3. Biblioteca "All Notes" (v1)

- Janela normal (pode ativar o app), aberta pelo menu bar ou atalho.
- Busca full-text simples em memória (título + corpo).
- Filtros: All / Active / Archived.
- Ações por nota: arquivar/reativar, deletar (confirmação), exportar .md.
- Import de arquivos .md/.txt (viram notas novas).

## 4. Fase 2 — deck esquerdo (Day)

- Configuração no menu bar: URL do Day + token `day_…`, token no Keychain.
- `DayClient` HTTP fino no Core, chamando os mesmos endpoints que o MCP do Day
  (`day/mcp/server.mjs`) usa: listar tarefas/board, criar tarefa, atualizar
  status, comentar.
- Deck esquerdo: uma "nota" por tarefa ativa; cor derivada da coluna do board.
  Abrir a tarefa mostra descrição + botões de mudança de status + comentário
  rápido. `+` cria tarefa nova.
- Ação "enviar pro Day" numa nota do deck direito: cria tarefa com o conteúdo;
  a nota guarda o link/id da tarefa no frontmatter (`dayTaskId`).
- Offline: leitura do último cache em disco; operações de escrita exigem rede
  (sem fila de sincronização na v1 — YAGNI).

## 5. Arquitetura / estrutura do repo

Mesmo padrão do projeto `notch` do Luis (SwiftPM, sem projeto Xcode):

```
edge-notes/
  Package.swift            # macOS 14+
  Sources/
    EdgeNotesCore/         # modelo, store markdown, frontmatter, FSEvents, DayClient
    EdgeNotesApp/          # AppKit/SwiftUI: panels, deck, biblioteca, menu bar
  Tests/
    EdgeNotesCoreTests/
  Scripts/
    bundle.sh              # gera EdgeNotes.app com Info.plist (LSUIElement)
  docs/superpowers/specs/
```

- `EdgeNotesCore` sem dependência de UI — 100% testável.
- Frontmatter: parser YAML mínimo próprio (só chaves planas usadas acima);
  sem dependência externa.
- TDD no Core (store, parser, ordenação, DayClient com URLProtocol fake).
- UI (panels, animações) verificada manualmente.

## 6. Erros

- Arquivo .md malformado (frontmatter inválido): nota carrega com defaults
  (título = primeira linha, cor default), nunca crasha nem perde corpo.
- Falha de escrita no autosave: retry no próximo tick; erro persistente vira
  alerta discreto no deck.
- Day API fora do ar (fase 2): deck esquerdo mostra estado "offline" com cache.

## Fora de escopo (por ora)

- Sync entre máquinas / iCloud.
- Pasta de notas configurável (fase posterior).
- Fila offline de escrita pro Day.
- Atalhos globais de teclado (avaliar depois da v1).
