# Roteiro de falas — Apresentação Parte 1 (AV1), grupo g07

**Tempo: 5 minutos, corte rígido** + 2 minutos de perguntas.
Orçamento abaixo: **295s**, deixando ~5s de folga. Se atrasar, corte o slide 6 (schema) —
é o único cujo conteúdo o professor consegue ver sozinho no repositório.

> As falas estão escritas para **serem faladas**, não lidas. Decore a **âncora** de cada slide
> (a frase que não pode faltar) e fale o resto com suas palavras.

---

## Distribuição sugerida entre os integrantes

O professor pode escolher **qualquer decisão** e perguntar a **qualquer membro**. Isso significa
que dividir a fala não basta — todo mundo precisa conseguir defender qualquer decisão. Use a
divisão abaixo para a apresentação e o banco de perguntas (no fim) para o Q&A.

| Slides | Bloco | Sugestão |
|---|---|---|
| 1–2 | Cenário e pergunta | Integrante A |
| 3–4 | Arquitetura e modelagem | Integrante B |
| 5–6 | Qualidade e schema | Integrante C |
| 7–8 | Resultado e custo | Integrante D |
| 9–10 | Infraestrutura e fechamento | Integrante E |

---

## Slide 1 — Capa · 10s

> Bom dia. Grupo g07. A gente construiu um data lake na AWS, todo em Terraform, sobre o catálogo
> público de vulnerabilidades que já estão sendo exploradas em ataques reais — e mediu quanto
> custa cada consulta.

**Âncora:** "vulnerabilidades que já estão sendo exploradas — não teóricas".

---

## Slide 2 — Cenário e pergunta de negócio · 30s

> A CISA mantém o catálogo KEV. A diferença dele para uma base comum de CVE é que aqui só entra
> vulnerabilidade com exploração **confirmada em ataque real**.
>
> O problema de qualquer time de segurança é sempre o mesmo: existem mais vulnerabilidades do que
> capacidade de corrigir. Então a pergunta que a gente escolheu é a que decide a fila:
> **quais fabricantes concentram as vulnerabilidades exploradas nos últimos 12 meses?**
>
> E, como isso é uma disciplina de engenharia de dados, tem uma segunda pergunta junto:
> **quanto custa responder isso?**

**Âncora:** "mais vulnerabilidades do que capacidade de corrigir — a pergunta decide a fila".
**Números:** 1.710 CVEs no catálogo · 296 nos últimos 12 meses · 117 fabricantes.

---

## Slide 3 — Arquitetura · 35s

> O feed é público, JSON, sem autenticação. A gente traz ele para a camada **raw** exatamente como
> veio, byte a byte — essa camada é a prova de origem: se a regra de limpeza mudar, dá para
> reconstruir tudo a partir dela.
>
> Da raw para a **trusted** acontece a limpeza e a tipagem, e aí o dado vira JSON de uma linha por
> registro. Essa camada é a que o Glue cataloga, com o schema declarado por nós — **sem Crawler**.
> E o Athena consulta por cima, dentro de um WorkGroup com limite de varredura.
>
> Tudo isso é Terraform, empacotado como módulo, com backend remoto e workspace.

**Âncora:** "a camada raw é a prova de origem".
**Se perguntarem por que duas camadas:** porque limpeza destrutiva em cima do único arquivo
armazenado é irreversível.

---

## Slide 4 — Granularidade · 35s

> O grão da tabela é **uma linha por CVE**. E ele não está só no documento: está declarado como
> parâmetro da tabela no próprio Glue, e é **provado por uma query** que roda
> `count(*) menos count(distinct cve_id)` e tem que dar zero.
>
> A gente considerou um grão mais fino, por par CVE e produto. Descartamos **com número**: o campo
> produto é texto livre, e **214 dos 1.710 registros**, 12,5%, têm separador ambíguo.
>
> Repara na diferença: "NetScaler ADC **and** NetScaler Gateway" são dois produtos. "Community
> Edition **and** Enterprise Edition" é um produto só, em duas edições. Não existe regra
> determinística que separe os dois casos. Quebrar pelo separador inflaria a contagem de produtos
> por fabricante — que é justamente o que a pergunta mede.

**Âncora:** "descartamos com número: 214 de 1.710, 12,5%".
**Cuidado:** não diga "o grão é único" — diga "**medimos** 1.710 linhas para 1.710 cve_id distintos".

---

## Slide 5 — Qualidade raw → trusted · 30s

> Essa tabela é o que a camada trusted conserta. O caso mais importante é o primeiro: **18 linhas**
> tinham espaço sobrando no nome do fabricante ou do produto.
>
> Parece detalhe cosmético, mas não é. O valor "SimpleHelp" com espaço no fim aparece em quatro
> registros. Se amanhã aparecer um "SimpleHelp" sem espaço, o `GROUP BY` cria **dois grupos** para o
> mesmo fabricante. Ou seja: é a diferença entre um ranking certo e um ranking **silenciosamente
> errado** — daqueles que ninguém percebe.
>
> E a ingestão só publica se as cinco barreiras passarem. A barreira de grão **bloqueia o upload**.

**Âncora:** "silenciosamente errado — daqueles que ninguém percebe".

---

## Slide 6 — Schema em IaC · 25s
*(este é o slide a cortar se estiver atrasado)*

> As 15 colunas estão declaradas em Terraform, de uma fonte de verdade só. A gente não usou Crawler,
> e não foi só porque o guia pede: um Crawler custa cerca de **7 centavos de dólar por execução**,
> por causa do mínimo de 10 minutos. Sobre um schema estável, ele estaria **pagando para
> redescobrir o que a gente já sabe** — e ainda podendo mudar o tipo entre execuções.
>
> Schema como código custa zero, passa por code review, e quebra no `plan` em vez de quebrar depois.

**Âncora:** "pagando para redescobrir o que a gente já sabe".

---

## Slide 7 — O resultado · 45s **(ponto alto 1)**

> Esse é o ranking. Microsoft concentra 48 das 296 vulnerabilidades do período — 16% sozinha. Os
> cinco maiores juntos dão 33%.
>
> Só que o número da direita é o que realmente muda a decisão. Das 48 da Microsoft, **5** estão
> ligadas a ransomware: 10%. Das 7 da Oracle, **3** estão: **43%**.
>
> Ou seja: **volume não é risco**. Quem monta a fila de correção só pelo topo do ranking trata a
> Oracle como sétima prioridade — sendo que quase metade das vulnerabilidades dela já foi usada em
> ransomware de verdade.
>
> É por isso que a consulta não devolve só a contagem: ela devolve a contagem, os produtos
> afetados, e o recorte de ransomware junto.

**Âncora:** "volume não é risco".
**Este é o slide que diferencia o trabalho. Não corra nele.**

---

## Slide 8 — Custo medido · 45s **(ponto alto 2)**

> A consulta varre 1,5 milhão de bytes. Mas o Athena tem um mínimo de cobrança de **10 megabytes
> por query**. Então o que a gente paga não é o que varre: paga o mínimo.
>
> Dá **quatro centésimos de milésimo de dólar** por execução — cerca de **21 mil execuções por
> dólar**.
>
> E aqui está a decisão de engenharia mais importante da entrega. Todo mundo pergunta por que não
> usamos Parquet. A resposta tem número: o dataset inteiro cabe **sete vezes** dentro do mínimo
> cobrável. Parquet, partição e compressão reduziriam os bytes lidos — e **não reduziriam um
> centavo da conta**, porque a conta já está no piso.
>
> A economia medida dessa otimização seria **zero dólares**. Por isso ela entra na Parte 2, quando o
> volume passar do piso. É decisão por número, não por calendário.

**Âncora:** "a economia medida seria zero dólares — por isso fica para a Parte 2".
**Se o professor cutucar:** essa é a defesa mais forte do trabalho. Mostre que você sabe *quando*
Parquet vale, não que você não sabe usar Parquet.

---

## Slide 9 — Disciplina de infraestrutura · 25s

> Quatro coisas rápidas. O workspace `av1` gera os nomes exigidos; qualquer outro ganha sufixo,
> porque nome de bucket S3 é **global** — um teste nosso em paralelo derrubaria o ambiente avaliado.
> O workspace `default` é **bloqueado** antes de criar recurso.
>
> O SQL mora no Terraform como named query, e o script executa **por ID** — o que roda não pode
> divergir do que foi revisado.
>
> E o destroy é **verificado**: o Terraform devolve sucesso mesmo deixando recurso órfão, então a
> gente confere os cinco recursos na AWS depois e falha se sobrou alguma coisa.

**Âncora:** "o Terraform devolve sucesso mesmo deixando órfão — por isso conferimos".

---

## Slide 10 — Fechamento · 15s

> Resumindo: cada decisão dessa tabela tem um número medido atrás, não uma justificativa escrita.
> Para a Parte 2, a prioridade é volume que ultrapasse o piso de cobrança — porque só aí Parquet e
> particionamento passam a ter economia mensurável. Obrigado.

**Âncora:** "cada decisão tem um número atrás, não uma justificativa escrita".

---

# Banco de respostas para o Q&A (2 minutos)

O professor pode escolher **uma decisão aleatória** e perguntar a **um membro específico**.
Todo mundo deve conseguir responder qualquer uma destas em **duas frases**.

### "Por que o grão é por CVE e não por produto?"
Porque medimos: 214 dos 1.710 registros (12,5%) têm separador ambíguo no campo produto, e o mesmo
` and ` às vezes separa dois produtos e às vezes duas edições do mesmo produto. Sem regra
determinística, quebrar por separador inflaria o próprio indicador que a pergunta mede.

### "Por que não usou Parquet / particionamento?"
Porque a economia medida seria USD 0,00. O dataset tem 1,43 MB e o Athena cobra um mínimo de 10 MB
por query — cabemos 7 vezes dentro do piso. Reduzir bytes lidos não reduz a fatura quando ela já
está no mínimo. Entra na Parte 2, quando o volume ultrapassar o piso.

### "Como você sabe que o custo é esse?"
O Athena reporta `DataScannedInBytes` na própria execução. O script lê esse valor, aplica o mínimo
de 10 MB e a tabela de preço de us-east-1 (USD 5,00/TB), e grava em `docs/evidence/query-cost.json`.
O número não foi estimado, foi lido da execução.

### "Por que não usou Glue Crawler?"
Além de o guia pedir, o Crawler custa ~USD 0,073 por execução (mínimo de 10 minutos) para
redescobrir um schema de 15 colunas que é estável e que a gente já conhece. E ele pode inferir tipo
diferente entre execuções. Schema declarado custa zero e passa por code review.

### "Por que as datas são string e não date?"
Porque o arquivo é NDJSON, onde todo valor é texto. Forçar `date` no JSON SerDe transforma qualquer
falha de parsing em NULL silencioso — e isso corromperia exatamente o filtro de 12 meses da nossa
pergunta. A barreira de ingestão garante 0 datas fora do ISO-8601, e a query faz o cast explícito.
Tipagem nativa vem na Parte 2, com Parquet, onde o tipo é carregado pelo formato.

### "O que garante que não tem CVE duplicado?"
Duas barreiras independentes. Na ingestão, antes de publicar, comparamos linhas e `cve_id` distintos
e abortamos se divergirem. Depois de publicado, uma named query no Athena faz
`count(*) - count(distinct cve_id)` e tem que dar zero. Medimos 1.710 e 1.710.

### "Por que raw e trusted separados, se o guia não pede camadas?"
Porque limpeza é destrutiva. A raw guarda o documento como veio, então qualquer resultado pode ser
reconstruído se a regra mudar. Não é medalhão — são duas camadas, e a refined fica para a Parte 2.

### "Por que DynamoDB para o lock, se o Terraform 1.10 já trava no S3?"
Decisão consciente: o `use_lockfile` do S3 é hoje a recomendação da HashiCorp para projeto novo e
dispensaria o DynamoDB. Usamos DynamoDB porque o guia exige explicitamente, e o critério de
avaliação pesa mais que a modernização. Está registrado assim no DECISOES.md.

### "O que acontece se rodarem o destroy e sobrar recurso?"
O script falha com código diferente de zero. Ele não confia no retorno do Terraform, que reporta
sucesso mesmo quando remove o recurso do state sem remover da conta — ele consulta os 5 recursos
na AWS depois do destroy.

### "Esse volume não é pequeno demais?"
É pequeno, e isso é uma escolha da Parte 1: o dado é público, real, reprodutível na conta de vocês
e tem sujeira genuína. O volume é justamente o que torna a decisão de custo interessante nesta
fase, porque expõe o piso de cobrança do Athena. Para a Parte 2, a gente precisa de volume acima
desse piso para que particionamento tenha economia mensurável.

---

## Checklist antes de apresentar

- [ ] Preencher os nomes dos integrantes no slide 1.
- [ ] Rodar o pipeline na AWS e conferir que `docs/evidence/query-cost.json` traz
      `cost_usd = 0.00004768`. **Se o número real divergir, atualizar o slide 8 e o DECISOES.md.**
- [ ] Conferir os números do slide 7 contra `docs/evidence/business-question-result.csv`
      (a janela de 12 meses é relativa a `current_date`, então pode mudar alguns valores).
- [ ] `verificacao/verifica.sh` com credenciais → 25/25 PASSA, e guardar a saída.
- [ ] Gravar o vídeo do `apply` → `ingest` → `query` → `destroy`, caso a demo ao vivo falhe.
- [ ] Cronometrar pelo menos um ensaio completo. 5 minutos é corte rígido.
