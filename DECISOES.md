# Decisões de engenharia — EDA262, grupo g07

*English: [DECISIONS.md](DECISIONS.md). Este arquivo em português é a cópia avaliada —
o nome `DECISOES.md` é exigido pelo guia da disciplina.*

Cada decisão abaixo é justificada por um número medido, não por prosa. A coluna *como medir*
indica o comando que reproduz o número em qualquer máquina.

- [Parte 1 (AV1)](#parte-1-av1) — data lake mínimo sobre o CISA KEV, decisões 1 a 10.
- [Parte 2 (AV2)](#parte-2-av2) — três camadas, Parquet particionado, carga idempotente e
  incremental, Lake Formation, decisões 11 a 24.

# Parte 1 (AV1)

**Fonte:** catálogo público CISA KEV (Known Exploited Vulnerabilities).
**Snapshot de referência:** `catalogVersion` **2026.09.16**, com **1.713** registros.
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
| Registros no feed | **1.713** |
| `cveID` distintos | **1.713** |
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
Ela foi descartada com número: o feed entrega `product` como texto livre, e **214 dos 1.713
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
| Unicidade de `cve_id` | **100%** (1.713/1.713) |
| `cve_id` vazios ou nulos | **0** |
| Formato | `CVE-AAAA-NNNNN`, padrão MITRE |

**Por que sem surrogate key:** a chave natural já é estável, global, única e legível por humanos.
Uma surrogate key acrescentaria 1.713 valores sem remover nenhuma ambiguidade — custo sem retorno
mensurável. O pipeline valida a unicidade em duas barreiras independentes: no `ingest.sh`, antes de
publicar, e na named query de granularidade, depois de publicado.

---

## 3. Transformação raw → trusted

**Decisão:** a camada raw guarda o documento original byte a byte; a trusted guarda JSON delimitado
por linha (NDJSON), limpo e tipado.

| Evidência | Valor |
|---|---|
| Raw | **1.727.984 bytes** (1 objeto JSON, array aninhado) |
| Trusted | **1.502.572 bytes** (1.713 linhas) |
| Variação de tamanho | **−13,0%** |
| Bytes médios por linha | **877** |

**Por que NDJSON e não o JSON original:** o `JsonSerDe` do Athena lê **um objeto por linha**. O
documento da CISA é um único objeto contendo um array de 1.713 itens — apontar a tabela para ele
retornaria **1 linha**, não 1.713. A conversão é obrigatória para a tabela ser consultável, não é
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
| `knownRansomwareCampaignUse` como texto | `Known` 360 / `Unknown` 1.353 | booleano |
| `forensicTriage` como texto | `Yes` 55 / `No` 1.658 | booleano |
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
| `date_added` fora do padrão ISO-8601 | **0 de 1.713** |
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
| Tamanho da tabela trusted | **1.502.572 bytes** (~1,43 MB) |
| **Volume varrido pela consulta** (medido na AWS) | **3.005.144 bytes** |
| Mínimo cobrado pelo Athena | **10.485.760 bytes** (10 MB) |
| Volume efetivamente cobrado | **10.485.760 bytes** |
| Tempo de execução do motor | **555 ms** (total 753 ms) |
| Preço (us-east-1) | **USD 5,00 por TB** |
| **Custo por consulta** | **USD 0,00004768** |
| Consultas por USD 1,00 | **≈ 20.973** |

**Um achado da medição:** o volume varrido é **exatamente 2,00× o tamanho da tabela**
(3.005.144 = 2 × 1.502.572). A causa é a subconsulta escalar
`(SELECT count(*) FROM window_kev)`, usada para calcular o percentual de concentração: o Athena
não materializa a CTE, então ele **lê os dados duas vezes** — uma para a agregação por fabricante,
outra para o total.

Isso é exatamente o tipo de coisa que só aparece medindo. A projeção feita sobre o tamanho do
arquivo teria subestimado a varredura pela metade. Não alteramos a consulta porque o custo não muda
(continuamos abaixo do piso), mas o comportamento está registrado: com volume maior, na Parte 2,
essa dupla leitura passa a ter preço e a consulta precisará ser reescrita.

Execução de referência: `03e82f7a-6abf-4205-92a4-0cddb5874d46` (`docs/evidence/query-cost.json`).

Fórmula: `custo = max(bytes_varridos, 10.485.760) ÷ 1.099.511.627.776 × 5,00`

**O número decisivo:** mesmo varrendo o dobro do arquivo, a consulta lê 3.005.144 bytes e cabe
**3,5 vezes** dentro do mínimo cobrável de 10 MB. Qualquer otimização de varredura — Parquet, particionamento, compressão — reduziria os bytes
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
| 1 | Granularidade: 1 linha por CVE | 1.713 linhas / 1.713 `cve_id` / **0** duplicatas |
| 2 | Chave natural `cve_id` | **100%** única, **0** vazias |
| 3 | Trusted em NDJSON | 1 objeto → **1.713** linhas consultáveis |
| 4 | Limpeza de espaços | **18 → 0** linhas sujas (1,05%) |
| 5 | Schema declarado, sem Crawler | **15** colunas, **0** Crawlers, **USD 0,073** evitados por crawl |
| 6 | Custo por consulta | **USD 0,00004768** (piso de 10 MB) |
| 7 | Guardrail do WorkGroup | **100 MB**, ~70× o dataset |
| 8 | Backend S3 + DynamoDB | **< USD 0,01/mês** |
| 9 | Workspace `av1` | **0** colisões de nome |
| 10 | Destroy verificado | **5** recursos conferidos, **0** órfãos |

---

# Parte 2 (AV2)

**Fontes:** CISA KEV (dimensão, catálogo de CVEs exploradas) + FIRST EPSS (fato, um
snapshot diário com a probabilidade de exploração de cada CVE).
**Pergunta de negócio:** quais fabricantes concentram as vulnerabilidades ativamente
exploradas (KEV) dos últimos 12 meses, qual a probabilidade de exploração (EPSS) dessas
vulnerabilidades ao longo de uma janela de 30 dias — e quanto custa responder isso no Athena?
**Janela de referência das medições na fonte:** EPSS de 2026-09-21 a 2026-10-20 (30 dias);
KEV `catalogVersion` 2026.10.16 (1.748 entradas) e o catálogo publicado em seguida (1.754).
O KEV muda ao longo da semana, e cada carga registra a versão que usou (`kev_catalog_date`).

> **Como medir (fonte):** `scripts/part-2/profile_sources.sh --days 30 --to 2026-10-20` —
> DuckDB local, sem conta AWS.
> **Como medir (AWS):** `scripts/part-2/run_all.sh` grava tudo em `docs/evidence/part-2/`.
> **Execução de referência na AWS:** 2026-10-20, us-east-1, janela 2026-09-21 a 2026-10-20 e KEV
> `catalog_date` 2026-10-20 (1.754 entradas). Os números *medido na AWS* vêm do
> `DataScannedInBytes` reportado pelo próprio Athena. Números marcados *calculado* derivam de bytes
> medidos e da regra de cobrança (USD 5,00/TB, mínimo de 10 MB por consulta). Um número ainda não
> medido leva a marca "pendente" em maiúsculas, e o `verifica.sh` reprova a entrega enquanto
> houver alguma.

---

## 11. Fonte de volume: EPSS como fato, KEV como dimensão

**Decisão:** acrescentar o EPSS diário como tabela fato; o KEV vira dimensão.

| Evidência | Valor |
|---|---|
| KEV inteiro na trusted da Parte 1 | **1.502.572 B** — 7× abaixo do piso de 10 MB |
| Economia possível com Parquet/partição só sobre o KEV | **USD 0,00** (a cobrança já está no piso) |
| EPSS por dia (média de 30 dias) | **383.988** linhas, **2.697.242 B** gzip |
| EPSS na janela de 30 dias | **11.519.635** linhas, **80.917.274 B** gzip |
| Mediana de EPSS: CVEs do KEV × todas as CVEs | **0,4895** × **0,00645** (76×) |
| CVEs com EPSS ≥ 0,10: KEV × todas | **73,4%** × **4,42%** |

**Por quê:** a Parte 2 avalia redução de custo, e só um volume acima do piso de cobrança torna
essa redução mensurável. A Parte 1 já tinha provado que o KEV sozinho não sai do piso. O EPSS
traz volume e informação: ele separa, entre as CVEs exploradas, as que continuam com alta chance
de exploração. A alternativa NVD (393.026 CVEs) não tem snapshot diário, e o snapshot diário é o
que dá partição natural, backfill e carga incremental.

---

## 12. Três camadas: raw, trusted e refined

**Decisão:** raw guarda os bytes como publicados; trusted guarda dados validados e tipados em
Parquet; refined guarda a resposta de negócio pré-agregada.

| Camada | Conteúdo | Tamanho no S3 (30 dias, medido na AWS) |
|---|---|---|
| raw | EPSS `.csv.gz` + KEV original (arquivo) + KEV em linhas JSON | **84.128.911 B** em 32 objetos |
| trusted | `epss_scores` + `kev_vulnerabilities`, Parquet ZSTD | **92.134.226 B** em 31 objetos |
| refined | `vendor_exposure_daily`, fabricante × dia | **358.795 B** em 30 objetos, 8.569 linhas |

**Por quê:** a raw preserva a reexecução: se uma regra de limpeza mudar, a trusted é rederivada
sem baixar nada de novo. A refined é **257× menor** que a trusted e responde a pergunta sem
refazer o join de 11,5 milhões de linhas a cada execução. A trusted ficou maior que a raw, e a
decisão 16 explica por quê.

**Reenquadramento do KEV na raw:** o `JsonSerDe` lê um objeto por linha, e o documento da CISA é
um único objeto. A ingestão grava o original byte a byte (arquivo, fora de qualquer tabela) e uma
cópia em linhas JSON (1.792.713 B → 1.398.932 B no catálogo 2026.10.16). Uma barreira compara as
duas com `jq` e só publica se forem **idênticas valor a valor**.

---

## 13. Granularidade de cada tabela

| Tabela | Grão declarado no Glue | Medido na AWS (linhas / chaves distintas / duplicadas) |
|---|---|---|
| `trusted.epss_scores` | uma linha por `(cve_id, snapshot_date)` | **11.519.635** / **11.519.635** / **0** |
| `trusted.kev_vulnerabilities` | uma linha por `(cve_id, catalog_date)` | **1.754** / **1.754** / **0** |
| `refined.vendor_exposure_daily` | uma linha por `(vendor_project, snapshot_date)` | **8.569** / **8.569** / **0** (≈ 286 fabricantes/dia) |

Como medir (AWS): a named query `eda262-g07-grain-check` agrupa cada tabela pela própria chave e
retorna `duplicate_rows` (`docs/evidence/part-2/grain-check-result.csv`). As três contagens batem
exatamente com as que o DuckDB mediu localmente sobre os mesmos arquivos.

**Por que a refined é por fabricante e não por CVE:** a pergunta é sobre fabricantes. Uma refined
por CVE teria 1.754 × 30 = **52.620** linhas para reagrupar a cada consulta, 6× mais. Para a média
de vários dias continuar exata, a refined guarda `epss_sum` e `epss_scored_cves`: a média da janela
é `soma ÷ contagem`, não uma média de médias.

---

## 14. Chaves

**Decisão:** chaves naturais compostas, sem surrogate key, e a chave de partição faz parte delas.

| Evidência | Valor |
|---|---|
| Duplicatas de `(cve_id, snapshot_date)` em 30 dias de EPSS | **0** em 11.519.635 linhas |
| `cve_id` fora do padrão `CVE-AAAA-NNNN+` | **0** |
| Fabricantes distintos × distintos ignorando maiúsculas | **290** × **290** |

**Por quê:** a chave natural já é única e estável. Como a data faz parte da chave, recarregar um
dia substitui exatamente as linhas daquele dia, e é isso que permite a idempotência da decisão 19.
A igualdade 290 × 290 mostra que nenhum fabricante aparece com grafias diferentes, então o
`GROUP BY vendor_project` não divide grupos.

---

## 15. Particionamento

**Decisão:** EPSS (trusted e refined) particionado por `snapshot_date`, um dia por partição; KEV
particionado por `catalog_date`, um snapshot por partição. Chaves de partição em `string` ISO-8601,
em que a ordem alfabética é a ordem cronológica.

| Evidência (coluna `epss`, medido na AWS) | Valor |
|---|---|
| Consulta de 1 dia | **779.638 B** varridos |
| A mesma consulta sobre 30 dias | **22.606.275 B** varridos |
| Economia de uma consulta de 1 dia por causa da partição | **29,0×** (o DuckDB previu 29,5×) |
| Tamanho de uma partição diária no S3 (todas as colunas) | **≈ 3,1 MB** (3.106.499 B em 2026-10-20) |

Como medir (AWS): `run_query.sh` executa a named query `epss-scan-profile` para 1 dia e para a
janela inteira, e grava as duas varreduras em `cost-comparison.json`.

**Alternativas rejeitadas:**

| Alternativa | Por que não |
|---|---|
| Sem partição | Uma pergunta sobre 1 dia lê o histórico todo. Com 1 ano (projeção a partir dos 779.638 B/dia medidos): ≈ 285 MB → USD 0,00129 por consulta, contra o piso de USD 0,0000477 (**27×**) |
| Partição mensal | Uma pergunta sobre 1 dia lê o mês inteiro: até **29,0×** mais bytes (medido) |
| KEV por ano de `date_added` | 6 partições de 186 a 555 linhas, num catálogo inteiro de **170.484 B** em Parquet: arquivos de dezenas de KB e nenhuma economia, já que a tabela inteira está abaixo do piso |

**Partition projection na raw:** as tabelas raw derivam as partições das propriedades da tabela.
Carregar um dia é só um upload no S3: **0** `MSCK REPAIR` e **0** chamadas de registro de
partição. Na trusted e na refined, o próprio `INSERT INTO` do Athena registra as partições.

---

## 16. Formato: Parquet + ZSTD

**Decisão:** trusted e refined em Parquet com compressão ZSTD (`parquet.compression = ZSTD` na
tabela, respeitado pelo `INSERT INTO`: as 6 colunas do arquivo gravado pelo Athena estão em ZSTD).

| Um dia (2026-10-20, 391.915 linhas) | Bytes |
|---|---|
| CSV gzip (como publicado, raw) | **2.748.018** |
| **Parquet ZSTD gravado pelo Athena** (medido no S3) | **3.106.499** (+13,0%) |
| Parquet ZSTD gravado pelo DuckDB (local, referência) | 2.704.197 |
| Parquet Snappy (DuckDB, local) | 5.203.860 |
| Colunas que a pergunta lê no arquivo do Athena (`cve_id` + `epss`) | **1.936.387** (62,3%) |

**O achado, em duas partes:**

1. **O Parquet não encolheu o arquivo; ficou 13% maior que o CSV gzip.** O writer do Athena
   (`parquet-mr-trino`) grava `cve_id` sem dicionário (encoding `PLAIN`): **1.129.503 B**, 2,3× os
   488.332 B do DuckDB. Isso só apareceu porque medimos o arquivo que o Athena gravou em vez de
   confiar na estimativa local.
2. **Mesmo assim o Parquet reduz o custo, porque o custo é o que se lê, não o que se guarda.** A
   pergunta lê 2 das 6 colunas. Medido na AWS: **56.913.236 B** a partir da trusted contra
   **82.325.456 B** a partir da raw, na mesma janela — **1,45× menos**. O CSV obriga a ler 100%
   de cada linha.

Além da leitura colunar, o Parquet traz **tipos de verdade** (`double`, `date`), cumprindo a
promessa da Parte 1 (decisão 5), e **estatísticas por bloco**. Entre os codecs, ZSTD ficou 1,92×
menor que Snappy; a vantagem de velocidade do Snappy não aparece em arquivos de 3 MB.

---

## 17. Meta de custo por consulta — declarada e cumprida

**Meta declarada:** a pergunta de negócio varre **no máximo 10.485.760 B** por execução, ou seja,
uma unidade de cobrança do Athena (**USD 0,00004768** em us-east-1). Está declarada na Terraform
(`cost_target_bytes_per_query`), é verificada pelo `run_query.sh` (que falha se a meta não for
cumprida) e pelo `verifica.sh`.

| Mesma pergunta, janela de 30 dias (medido na AWS) | Bytes varridos | Tempo do motor | Custo por execução |
|---|---|---|---|
| a partir da raw (CSV + JSON) | **82.325.456** | 4.554 ms | **USD 0,00037437** |
| a partir da trusted (Parquet) | **56.913.236** | 4.824 ms | **USD 0,00025881** |
| **a partir da refined** | **162.943** | **1.714 ms** | **USD 0,00004768** (piso) |

- **Meta cumprida com margem de 64×:** a refined varreu 162.943 B contra o limite de 10.485.760 B.
  A consulta filtra a janela pela partição, então a margem não cai com o crescimento do histórico.
  Uma janela de 1 ano (≈ 1,98 MB, projeção linear) ainda ficaria 5× abaixo da meta.
- **raw ÷ refined:** **505×** menos bytes, mas só **7,9×** no custo, porque o piso de 10 MB limita
  a economia. É o mesmo efeito medido na Parte 1, agora do lado que favorece a refined.
- **A camada não muda a resposta:** o `run_query.sh` comparou os três resultados e eles saíram
  **idênticos**, byte a byte (`cost-comparison.json`, `results_identical_across_layers = true`).
- **Estimativa × medição:** o DuckDB previu 36.545 B para a refined, e o Athena leu 162.943 B
  (4,5×). O Athena grava um arquivo por partição diária (30 arquivos de ≈ 12 KB), e cada arquivo
  carrega o próprio rodapé e cabeçalhos de coluna.

---

## 18. Transformação em SQL no Athena (não Glue ETL, não local)

**Decisão:** toda transformação é um `INSERT INTO ... SELECT` versionado em `parte-2/sql/etl/`.

| Alternativa | Custo de uma carga de 30 dias |
|---|---|
| **Athena INSERT** (escolhida) | **80.917.274 B** varridos → **USD 0,00036797** (medido na AWS) |
| Glue ETL (Spark), execução mínima | 2 DPU × 1 min × USD 0,44/DPU-h = **USD 0,0147** (preço de tabela, não medido): **40×** |
| Conversão local (DuckDB/pyarrow) | USD 0 de computação, mas cria dependência na máquina do avaliador e exige subir 80 MB |

**Uma leitura só, comprovada:** o metadado de cada arquivo EPSS (versão do modelo e data) é
espalhado para as linhas com uma função de janela, e não com um self-join. O Athena não materializa
CTEs, e a Parte 1 mediu exatamente **2,00×** de varredura numa CTE lida duas vezes. Na AWS, o
`INSERT` do backfill varreu **80.917.274 B — exatamente o total byte a byte dos 30 arquivos gzip**.
Com o self-join seriam 161,8 MB.

---

## 19. Ingestão idempotente: sobrescrita de partição

**Decisão:** toda escrita apaga o prefixo da partição no S3 e então executa o `INSERT INTO`. Na
raw, as chaves de objeto são determinísticas.

| Evidência | Valor |
|---|---|
| Recarga de 2026-10-20 nas três camadas: linhas na trusted antes → depois | **391.915 → 391.915** (medido na AWS) |
| A mesma recarga na refined | **290 → 290** |
| O que um `INSERT` só de acréscimo produziria | **783.830** e **580** linhas (2×) |

Como medir: `scripts/part-2/check_idempotency.sh` recarrega o dia mais novo pelos mesmos comandos
de uma execução agendada e grava `docs/evidence/part-2/idempotency-check.json`.

**Alternativa rejeitada:** `MERGE` sobre Iceberg (ACID). Exigiria outro formato de tabela, fora do
escopo da disciplina. Para snapshots diários que só recebem acréscimo, sobrescrever a partição dá a
mesma garantia com tabelas Hive. Se uma execução falhar no meio, a partição fica vazia ou parcial,
e reexecutar converge para o estado correto.

---

## 20. Carga incremental e backfill

**Decisão:** cada camada tem a própria marca d'água (*high-water mark*), que é a partição mais
nova que ela guarda. A primeira carga faz backfill de 30 dias; as seguintes carregam só o que o
EPSS publicou depois da marca. Um buraco atrás da marca é reportado, com o comando que o corrige.

| Evidência | Valor |
|---|---|
| Backfill de 30 dias num único `INSERT` (medido na AWS) | **80.917.274 B** → **USD 0,00036797** |
| Os mesmos 30 dias em 30 `INSERT`s diários | 30 × piso de 10 MB → **USD 0,00143** *calculado* (**3,9×** mais) |
| `INSERT` de 1 dia na trusted (medido na AWS) | **2.748.018 B** → abaixo do piso → USD 0,00004768 |
| `INSERT` de 1 dia na refined (medido na AWS) | **1.951.209 B** → abaixo do piso → USD 0,00004768 |
| Execução incremental completa de 1 dia (6 instruções, todas no piso) | **USD 0,000286** *calculado* a partir das medições acima |
| Lote máximo por `INSERT` | 30 partições (o Athena aceita até 100) |

```bash
scripts/part-2/run_pipeline.sh --days 30   # primeira carga (backfill)
scripts/part-2/run_pipeline.sh             # cargas seguintes (incremental)
```

**Por que uma marca por camada:** se uma execução morrer entre a trusted e a refined, a próxima
execução constrói na refined os dias que faltam, sem reprocessar a trusted.

**Histórico:** cada carga acrescenta uma linha a `docs/evidence/part-2/load-history.jsonl`. O
crescimento do lake até a apresentação fica registrado execução a execução.

---

## 21. Correção point-in-time

**Decisão:** num dia D, uma CVE só conta para o fabricante se a CISA já a tinha listado em D
(`date_added <= D`).

| Evidência | Valor |
|---|---|
| CVEs do KEV listadas depois do início da janela (2026-09-21) | **37** de 1.754 |

**Por quê:** a dimensão KEV é um snapshot mais novo que os dias do backfill. Sem essa regra, um dia
antigo contaria 37 CVEs que ainda não estavam no catálogo naquele dia, e a série histórica
mostraria exposição que não existia.

---

## 22. Controle de acesso por camada: Lake Formation

**Decisão:** três perfis de acesso, com leitura concedida por camada pelo Lake Formation.

| Perfil | raw | trusted | refined |
|---|---|---|---|
| `data-engineer` | ✓ | ✓ | ✓ |
| `data-analyst` | — | ✓ | ✓ |
| `business-user` | — | — | ✓ |

| Evidência | Valor |
|---|---|
| Combinações perfil × camada testadas ao vivo (medido na AWS) | **9 de 9** iguais à matriz: 6 concedidas, 3 negadas pelo Lake Formation |
| Grant padrão `IAMAllowedPrincipals` em banco/tabela novos | **removido** (0 entradas) |
| Permissões S3 dos perfis nos buckets do lake | **0** ações |
| Diferenças de política IAM entre os perfis | **0**, além do próprio WorkGroup e prefixo |

**Por quê:**

- Como a política IAM é idêntica em todos os perfis, uma consulta negada só pode ter sido negada
  pelo Lake Formation. O teste prova o mecanismo, não uma diferença de IAM.
- Sem remover o `IAMAllowedPrincipals`, qualquer principal com acesso IAM leria tudo, e os grants
  seriam decorativos.
- Os buckets são registrados com um papel próprio, e não com o service-linked role, que sobrevive
  ao `destroy` e seria um órfão.
- Cada perfil tem um WorkGroup e um prefixo de resultados próprios (**4** WorkGroups), seguindo a
  recomendação da AWS. O Lake Formation não governa o local dos resultados nem o histórico de
  consultas. Sem essa separação, um `business-user` leria o CSV de uma consulta de outro perfil
  sobre a raw.
- As configurações do Lake Formation valem para a conta inteira. O `deploy.sh` salva as originais
  antes de alterá-las, e o `destroy.sh` as restaura.

---

## 23. Guardrails de custo nos WorkGroups

| WorkGroup | Limite por consulta | Maior consulta legítima | Folga | Custo máximo |
|---|---|---|---|---|
| pipeline (`eda262-g07-wg`) | **200 MB** | pergunta sobre a raw, 30 dias: 82,3 MB (medido) | 2,5× | USD 0,00095 |
| perfis (3) | **100 MB** | pergunta sobre a trusted, 30 dias: 56,9 MB (medido) | 1,8× | USD 0,00048 |

A folga dos perfis caiu de 2,8× (estimada) para 1,8× (medida), por causa do encoding do writer do
Athena (decisão 16). Ela cobre a janela de 30 dias, mas uma análise de 60 dias na trusted seria
cancelada. Isso é intencional: análises longas devem usar a refined, que lê KB.

---

## 24. Destroy sem órfãos

**Decisão:** o `destroy.sh` confere na AWS cada recurso depois do `terraform destroy` e restaura as
configurações do Lake Formation da conta.

| Evidência | Valor |
|---|---|
| Recursos conferidos | **18** (4 buckets, 3 bancos Glue, 4 WorkGroups, 4 papéis IAM, 3 registros no Lake Formation) |
| Órfãos tolerados | **0** — AWS: **PENDENTE** (o lake fica no ar para as cargas incrementais até a apresentação; a medição acontece na destruição final) |

---

## Resumo dos números (Parte 2)

| # | Decisão | Número decisivo |
|---|---|---|
| 11 | EPSS como fato | **80,9 MB** em 30 dias, contra 1,5 MB do KEV inteiro |
| 12 | Três camadas | refined **257×** menor que a trusted no S3 |
| 13 | Granularidade | **0** duplicatas em 11.519.635 linhas (medido na AWS) |
| 14 | Chaves naturais compostas | **290 × 290** fabricantes, sem colisão de grafia |
| 15 | Partição diária | **29,0×** menos bytes numa consulta de 1 dia (medido na AWS) |
| 16 | Parquet + ZSTD | arquivo 13% maior que o CSV, mas a pergunta lê **1,45×** menos |
| 17 | Meta de custo | ≤ 10 MB; refined leu **162.943 B** (64× abaixo), USD 0,00004768 |
| 18 | SQL no Athena | **40×** mais barato que Glue ETL; backfill leu 1× a raw, não 2× |
| 19 | Sobrescrita de partição | recarga **391.915 → 391.915** (append dobraria) |
| 20 | Incremental + backfill | lote **3,9×** mais barato que cargas diárias |
| 21 | Point-in-time | **37** CVEs fora do lugar sem a regra |
| 22 | Lake Formation | **9 de 9** combinações iguais à matriz, **0** ações S3 nos perfis |
| 23 | Guardrails | **200 MB** / **100 MB** (folga medida 2,5× / 1,8×) |
| 24 | Destroy | **18** recursos conferidos |
