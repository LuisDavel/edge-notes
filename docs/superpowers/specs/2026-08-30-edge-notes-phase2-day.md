# edge-notes Fase 2 — integração com o Day

Data: 2026-08-30
Status: aprovado em conversa (deck esquerdo por coluna + janela kanban própria)
Spec da fase 1: `2026-08-30-edge-notes-design.md`

## Visão

A borda **esquerda** da tela ganha um deck espelhando o board do [Day](https://github.com/LuisDavel/day)
— o app de tarefas do próprio usuário. Uma aba por coluna do kanban; abrir uma aba
mostra as tarefas daquela coluna; abrir uma tarefa mostra o detalhe com ações. O
kanban completo (colunas lado a lado, drag & drop) vive numa janela própria, como
a biblioteca "All Notes" da fase 1.

O deck direito (notas markdown) não muda, exceto por uma ação nova: enviar uma nota
para o Day como tarefa.

## API do Day (levantada no repo `day`)

Base: `<DAY_URL>/api`, auth `Authorization: Bearer day_…` (token criado no app em
Configurações → Tokens de API, escopado ao workspace + RBAC do usuário).

| Endpoint | Uso |
| --- | --- |
| `GET /board?sprintId=` | Colunas da sprint ativa (`sprintId=backlog` para o backlog). Retorna `{ columns: [{ key, name, color, count, tasks: TaskDTO[] }] }` |
| `GET /tasks/{id}` | `TaskDetailDTO` — descrição, subtarefas, comentários, atividade |
| `POST /tasks` | Cria tarefa `{ title, priority?, parentId?, backlog? }` |
| `PATCH /tasks/{id}` | `{ status?, priority?, title?, description?, assigneeId? }` |
| `POST /tasks/reorder` | `{ taskId, toStatus?, toSprintId?, orderedIds }` — drag entre colunas |
| `POST /comments` | `{ taskId, body }` |
| `POST /tasks/{id}/timer` | Liga/desliga o timer da tarefa |
| `GET /sprints` | Lista de sprints (para o seletor da janela kanban) |
| `GET /my-work` | Tarefas do usuário (não usado na v1 desta fase; reservado) |

Status: `todo` · `in_progress` · `in_review` · `done`.
Prioridade: `none` · `low` · `medium` · `high` · `urgent`.

Campos de `TaskDTO` que a UI usa: `id`, `title`, `status`, `priority`, `order`,
`assignee`, `labels`, `loggedSeconds`, `running`, `subtaskDone`/`subtaskTotal`,
`childCount`.

## 1. Configuração e credenciais

- Item novo no menu da barra: **Day Settings…** → janela pequena com URL do Day e
  campo de token.
- O token vive no **Keychain** (`kSecClassGenericPassword`, serviço
  `com.luisdavel.edgenotes.day`), nunca em `UserDefaults` nem em disco claro. A URL
  vai em `UserDefaults`.
- Botão "Testar conexão" faz `GET /board` e mostra sucesso/erro.
- Sem token configurado: o deck esquerdo não aparece. Nada de painel vazio.

## 2. `DayClient` (Core)

Cliente HTTP fino, sem dependências, em `EdgeNotesCore`:

- `struct DayCredentials { var baseURL: URL; var token: String }`
- `protocol DayAPI` com os métodos abaixo, e `final class DayClient: DayAPI`
  recebendo um `URLSession` injetável (testes usam `URLProtocol` falso):
  - `func board(sprintID: String?) async throws -> DayBoard`
  - `func task(id: String) async throws -> DayTaskDetail`
  - `func createTask(title: String, priority: DayPriority?, backlog: Bool) async throws -> DayTask`
  - `func updateTask(id: String, patch: DayTaskPatch) async throws`
  - `func reorder(taskID: String, toStatus: DayStatus?, orderedIDs: [String]) async throws`
  - `func comment(taskID: String, body: String) async throws`
  - `func toggleTimer(taskID: String) async throws -> DayTask`
  - `func sprints() async throws -> [DaySprint]`
- DTOs `Decodable` espelhando o `TaskDTO` do Day, tolerantes a campos novos
  (decodificação falha só no que a UI usa de fato).
- Erros tipados: `DayError.unauthorized` (401), `.forbidden` (403 — papel `viewer`),
  `.notFound`, `.server(status:message:)`, `.offline(underlying:)`.

## 3. `DayStore` (Core)

Estado observável do board, entre o cliente e a UI:

- Carrega o board, guarda a última resposta em cache no disco
  (`Application Support/EdgeNotes/day-board.json`).
- `refresh()` manual e automático a cada 60 s enquanto o deck/janela estiver visível
  (nunca com o app em segundo plano e nada aberto).
- Mutações são **otimistas**: aplica localmente, chama a API, e reverte + mostra erro
  se a chamada falhar.
- Offline (`.offline`): serve o cache, marca o estado como desatualizado e bloqueia
  escrita com mensagem clara. Sem fila de sincronização (YAGNI, igual à fase 1).

## 4. Deck esquerdo

Mesmo mecanismo de painel da fase 1 (`EdgePanel`), espelhado para a borda esquerda —
o código de painel/estados é compartilhado, não duplicado.

- **Repouso:** pill fina na borda esquerda; um traço por coluna, na cor da coluna
  (`column.color` vem do Day), com a contagem de tarefas.
- **Fan:** uma aba por coluna — *A fazer*, *Em progresso*, *Em revisão*, *Concluído* —
  rótulo vertical com nome e contagem.
- **Coluna aberta:** lista das tarefas daquela coluna. Cada linha: título, badge de
  prioridade, avatar/iniciais do responsável, indicador de subtarefas (`3/5`) e
  ponto pulsando se o timer estiver rodando.
- **Tarefa aberta:** título, descrição (renderizada com o mesmo highlighter markdown
  das notas), e ações — mudar status (segmented das 4 colunas), prioridade, iniciar/parar
  timer, e um campo de comentário rápido.
- Botão `+` no pé cria tarefa na coluna aberta (título inline).

## 5. Janela Kanban

Janela normal (pode ativar o app), como a biblioteca:

- Colunas lado a lado com as tarefas em cartões; seletor de sprint no topo
  (lista de `GET /sprints`, mais a opção *Backlog*).
- **Drag & drop** entre colunas e reordenação dentro da coluna →
  `POST /tasks/reorder` com a ordem resultante; aplicação otimista com reversão em erro.
- Clique num cartão abre o mesmo detalhe do deck, no painel direito da janela.
- Busca simples por título e filtro por responsável.

## 6. Ponte notas → Day

- Ação **Send to Day** na nota aberta do deck direito: cria uma tarefa cujo título é o
  título da nota e a descrição é o corpo markdown.
- A nota guarda `dayTaskId` no frontmatter; a partir daí o footer mostra o status da
  tarefa e um atalho para abri-la no deck esquerdo.
- Nada é sincronizado de volta automaticamente: a nota continua sendo a nota.

## 7. Erros

- 401 → estado "token inválido" com atalho para as configurações.
- 403 → ações de escrita ficam desabilitadas com a explicação (papel `viewer`).
- Offline → cache com aviso, escrita bloqueada.
- Falha numa mutação otimista → reverte, e a mensagem aparece no próprio card por
  alguns segundos (sem alert modal).

## Fora de escopo

- Fila offline de escrita, notificações do Day, whiteboards, docs, relatórios,
  timesheet, sprints CRUD (só leitura para o seletor).
