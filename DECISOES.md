# Decisões de engenharia — EDA262 Parte 1 (AV1), grupo g07

Cada decisão abaixo é justificada por um número medido, não por prosa. A coluna *como medir*
indica o comando que reproduz o número em qualquer máquina.

**Fonte:** catálogo público CISA KEV (Known Exploited Vulnerabilities).
**Snapshot de referência:** `catalogVersion` **2026.09.14**, com **1.710** registros.
**Pergunta de negócio:** quais fabricantes concentram o maior número de vulnerabilidades
ativamente exploradas (KEV) nos últimos 12 meses, e qual o custo dessa consulta no Athena?

> Os números marcados como **medido na fonte** foram apurados diretamente sobre o feed e são
> reproduzíveis offline. Os marcados como **medido na AWS** são gravados em
> `docs/evidence/query-cost.json` por `scripts/run_query.sh` durante o deploy e devem ser
> conferidos após o `apply`.

---

## 1. Granularidade (grain) da tabela trusted

**Decisão:** uma linha por CVE do catálogo KEV. A granularidade está declarada no próprio
Glue Data Catalog, no parâmetro `grain = "one row per cve_id"` da tabela.

| Evidência | Valor |
|---|---|
| Registros no feed | **1.710** |
| `cveID` distintos | **1.710** |
| Linhas duplicadas | **0** |

Como medir (fonte):

```bash
jq -r '"total=\(.vulnerabilities|length) distintos=\([.vulnerabilities[].cveID]|unique|length)"' \
  known_exploited_vulnerabilities.json
```

Como medir (AWS): a named query `eda262-g07-grain-check`, provisionada pelo Terraform, executa
`count(*) - count(DISTINCT cve_id)` sobre a tabela e precisa retornar **0**. O resultado fica em
`docs/evidence/grain-check-result.csv`.

**Por que essa e não outra:** a granularidade alternativa seria *uma linha por par (CVE, produto)*.
Ela foi descartada com número: o feed entrega `product` como texto livre, e **214 dos 1.710
registros (12,5%)** contêm separadores que podem indicar múltiplos produtos — **193** com `" and "`
e **49** com vírgula.

| Padrão em `product` | Registros |
|---|---|
| Contém `" and "` | **193** |
| Contém vírgula | **49** |
| União (` and `, `,`, `/`) | **214 (12,5%)** |

O separador é ambíguo, e é isso que decide a questão: em `"NetScaler ADC and NetScaler Gateway"` são
dois produtos, mas em `"Community Edition and Enterprise Edition"` são duas edições do mesmo produto.
Dividir pelo separador inflaria a contagem de produtos de um fabricante por artefato de parsing, bem
no indicador que a pergunta de negócio mede. Não existe regra determinística que separe os dois casos
sem inferência — então a granularidade por CVE é a única que o dado sustenta.

Como medir:

```bash
jq -r '[.vulnerabilities[]|select(.product|test(" and |,|/"))]|length' \
  known_exploited_vulnerabilities.json   # -> 214
```

---

## 2. Chave natural

**Decisão:** `cve_id` é a chave natural e única da tabela. Não há chave substituta (surrogate key).

| Evidência | Valor |
|---|---|
| Unicidade de `cve_id` | **100%** (1.710/1.710) |
| `cve_id` vazios ou nulos | **0** |
| Formato | `CVE-AAAA-NNNNN`, padrão MITRE |

**Por que sem surrogate key:** a chave natural já é estável, global, única e legível por humanos.
Uma surrogate key acrescentaria 1.710 valores sem remover nenhuma ambiguidade — custo sem retorno
mensurável. O pipeline valida a unicidade em duas barreiras independentes: no `ingest.sh`, antes de
publicar, e na named query de granularidade, depois de publicado.

---

## 3. Transformação raw → trusted

**Decisão:** a camada raw guarda o documento original byte a byte; a trusted guarda JSON delimitado
por linha (NDJSON), limpo e tipado.

| Evidência | Valor |
|---|---|
| Raw | **1.722.859 bytes** (1 objeto JSON, array aninhado) |
| Trusted | **1.497.926 bytes** (1.710 linhas) |
| Variação de tamanho | **−13,1%** |
| Bytes médios por linha | **875** |

**Por que NDJSON e não o JSON original:** o `JsonSerDe` do Athena lê **um objeto por linha**. O
documento da CISA é um único objeto contendo um array de 1.710 itens — apontar a tabela para ele
retornaria **1 linha**, não 1.710. A conversão é obrigatória para a tabela ser consultável, não é
preferência estética.

**Por que raw e trusted separados:** a camada raw preserva a prova de origem. Qualquer resultado pode
ser reconstruído a partir dela se a regra de limpeza mudar — o que não seria possível se a limpeza
fosse aplicada de forma destrutiva no único arquivo armazenado.

---

## 4. Limpeza aplicada na camada trusted

**Decisão:** normalizar espaços e converter strings-booleanas em booleanos reais.

| Problema medido na fonte | Antes | Depois |
|---|---|---|
| Espaço espúrio em `vendorProject` / `product` | **18 linhas (1,05%)** | **0** |
| `knownRansomwareCampaignUse` como texto | `Known` 360 / `Unknown` 1.350 | booleano |
| `forensicTriage` como texto | `Yes` 52 / `No` 1.658 | booleano |
| `cwes` sem contagem pré-calculada | array (0 a 4 itens; **175** vazios) | `cwe_count` int |

**Impacto direto na pergunta de negócio:** o valor `"SimpleHelp "` (com espaço ao final) aparece em
**4 registros**. Sem `TRIM`, qualquer ocorrência futura de `"SimpleHelp"` sem espaço geraria **dois
grupos distintos** no `GROUP BY vendor_project` — ou seja, a limpeza não é cosmética: ela é a
diferença entre um ranking correto e um ranking silenciosamente errado.

**Por que booleano e não string:** permite `count_if(is_known_ransomware_use)` em vez de comparar
strings mágicas, e elimina a chance de um valor novo no feed (`"Likely"`, por exemplo) ser contado
como positivo por engano.

Como medir:

```bash
scripts/ingest.sh --keep-local   # as 5 barreiras de qualidade imprimem cada número
```

---

## 5. Tipos declarados no Glue

**Decisão:** tipos ricos onde o formato sustenta (`boolean`, `int`, `array<string>`); datas como
`string` em ISO-8601.

| Evidência | Valor |
|---|---|
| Colunas declaradas explicitamente | **15** |
| `date_added` fora do padrão ISO-8601 | **0 de 1.710** |
| Glue Crawlers usados | **0** |

**Por que data como `string`:** o arquivo de apoio é texto — em NDJSON todo valor é texto. Forçar
`date` no `JsonSerDe` transforma qualquer falha de parsing em `NULL` silencioso, o que corromperia
justamente o filtro de 12 meses da pergunta de negócio. A consulta aplica `date(date_added)`
explicitamente, e a barreira de ingestão garante **0** datas fora do formato antes da publicação.
Tipagem nativa de data entra na Parte 2, junto com Parquet, onde o tipo é carregado pelo formato.

**Por que sem Glue Crawler:** além de ser exigência do guia, o Crawler tem custo de tabela de
**USD 0,44 por DPU-hora com mínimo de 10 minutos por execução** (≈ **USD 0,073** por crawl, preço de
tabela AWS, não medido por nós). Sobre um schema estável de 15 colunas, ele gastaria esse valor a
cada execução para redescobrir uma estrutura que já conhecemos — e ainda introduziria variação de
tipo entre execuções. O schema declarado em IaC custa **USD 0,00** e é revisável em *code review*.

---

## 6. Custo por consulta no Athena

**Decisão:** consultar a camada trusted diretamente, sem conversão colunar, aceitando varredura
integral — porque o volume torna a otimização irrelevante nesta fase.

| Evidência | Valor |
|---|---|
| Volume varrido pela consulta | **1.497.926 bytes** (~1,43 MB) |
| Mínimo cobrado pelo Athena | **10.485.760 bytes** (10 MB) |
| Volume efetivamente cobrado | **10.485.760 bytes** |
| Preço (us-east-1) | **USD 5,00 por TB** |
| **Custo por consulta** | **USD 0,00004768** |
| Consultas por USD 1,00 | **≈ 20.971** |

Fórmula: `custo = max(bytes_varridos, 10.485.760) ÷ 1.099.511.627.776 × 5,00`

**O número decisivo:** o dataset inteiro (1,43 MB) cabe **7 vezes** dentro do mínimo cobrável de
10 MB. Qualquer otimização de varredura — Parquet, particionamento, compressão — reduziria os bytes
lidos, mas **não reduziria um centavo da fatura**, porque a cobrança já está no piso. Converter para
Parquet nesta fase custaria esforço de engenharia com economia medida de **USD 0,00**. É por isso que
Parquet e particionamento pertencem à Parte 2, quando o volume passar do piso de cobrança — e não por
serem “avançados demais”.

Valor medido na AWS: `docs/evidence/query-cost.json`, campo `cost_usd`, gravado por
`scripts/run_query.sh` a partir de `DataScannedInBytes` reportado pelo próprio Athena.

---

## 7. Guardrail de custo no WorkGroup

**Decisão:** o Athena WorkGroup aplica `bytes_scanned_cutoff_per_query = 104.857.600` (100 MB) e
`enforce_workgroup_configuration = true`.

| Evidência | Valor |
|---|---|
| Limite por consulta | **100 MB** |
| Folga sobre o dataset atual | **≈ 70×** (1,43 MB → 100 MB) |
| Custo máximo por consulta com o limite | **USD 0,000477** |
| Consulta acidental de 1 TB | **cancelada pelo Athena** |

**Por que 100 MB:** é folgado o bastante para o dataset crescer uma ordem de grandeza sem falso
positivo, e apertado o bastante para que um `SELECT` mal escrito ou um `JOIN` acidental seja
cancelado antes de gerar fatura. `enforce_workgroup_configuration` impede que um cliente ignore o
limite ou grave resultados fora do bucket controlado.

---

## 8. Backend remoto: S3 + DynamoDB

**Decisão:** estado remoto em S3 com versionamento, bloqueio em tabela DynamoDB `PAY_PER_REQUEST`.

| Evidência | Valor |
|---|---|
| Versionamento do bucket de estado | **habilitado** (único caminho de recuperação) |
| Modo de cobrança do DynamoDB | **sob demanda** |
| Escritas por `apply` | **~2** (lock e unlock) |
| Custo mensal estimado do bloqueio | **< USD 0,01** |

**Alternativa considerada e rejeitada:** o Terraform ≥ 1.10 oferece bloqueio nativo no próprio S3
via `use_lockfile = true`, dispensando o DynamoDB — hoje é a prática recomendada pela HashiCorp para
projetos novos. Não foi adotada aqui porque **o guia da disciplina exige explicitamente S3 +
DynamoDB**, e o critério de avaliação pesa mais que a modernização. A decisão está registrada para
ser defendida na apresentação.

**Por que `PAY_PER_REQUEST`:** capacidade provisionada cobraria por hora ociosa. O padrão de uso são
poucas escritas por dia, concentradas em segundos — sob demanda é a única opção cujo custo acompanha
esse perfil.

---

## 9. Workspace do Terraform

**Decisão:** o workspace `av1` produz exatamente os nomes exigidos pelo guia; qualquer outro
workspace recebe seu nome como sufixo.

| Evidência | Valor |
|---|---|
| Nomes no workspace `av1` | `eda262-g07-lake-raw`, `eda262-g07-lake-trusted`, `eda262-g07-wg` |
| Nomes no workspace `dev` | `eda262-g07-lake-raw-dev`, ... |
| Colisões possíveis de nome de bucket | **0** |

**Por que isso importa com número:** nomes de bucket S3 são únicos **globalmente**, não por conta.
Sem o sufixo, um teste paralelo do grupo derrubaria ou bloquearia o ambiente avaliado. Com ele,
ambientes de teste coexistem sem risco, e o `apply` no workspace `default` é **bloqueado** por uma
`precondition` — falha no `plan`, antes de criar qualquer recurso.

---

## 10. Destruição sem recursos órfãos

**Decisão:** `force_destroy = true` nos buckets e no WorkGroup, com verificação ativa pós-`destroy`.

| Evidência | Valor |
|---|---|
| Recursos conferidos após o `destroy` | **5** (3 buckets, 1 banco Glue, 1 WorkGroup) |
| Órfãos tolerados | **0** |
| Resultados do Athena expirados por lifecycle | **7 dias** |

**Por que verificar em vez de confiar:** o `terraform destroy` retorna sucesso mesmo quando um
recurso foi removido do estado sem ser removido da conta. O `scripts/destroy.sh` consulta a AWS por
cada um dos 5 recursos depois do `destroy` e **falha com código diferente de zero** se qualquer um
ainda responder. O critério do guia é verificado, não presumido.

**Ressalva registrada:** `force_destroy` apaga objetos e versões sem confirmação. É aceitável aqui
porque 100% do dado é re-ingerível a partir de um feed público em um comando. Em um ambiente com
dado não reproduzível, esta decisão seria o oposto da correta.

---

## Resumo dos números

| # | Decisão | Número decisivo |
|---|---|---|
| 1 | Granularidade: 1 linha por CVE | 1.710 linhas / 1.710 `cve_id` / **0** duplicatas |
| 2 | Chave natural `cve_id` | **100%** única, **0** vazias |
| 3 | Trusted em NDJSON | 1 objeto → **1.710** linhas consultáveis |
| 4 | Limpeza de espaços | **18 → 0** linhas sujas (1,05%) |
| 5 | Schema declarado, sem Crawler | **15** colunas, **0** Crawlers, **USD 0,073** evitados por crawl |
| 6 | Custo por consulta | **USD 0,00004768** (piso de 10 MB) |
| 7 | Guardrail do WorkGroup | **100 MB**, ~70× o dataset |
| 8 | Backend S3 + DynamoDB | **< USD 0,01/mês** |
| 9 | Workspace `av1` | **0** colisões de nome |
| 10 | Destroy verificado | **5** recursos conferidos, **0** órfãos |
