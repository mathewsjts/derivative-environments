// O manifesto e a fonte de verdade sobre "o que existe neste build".
//
// Ele fica COMMITADO no repo (com features vazias na main) e e SOBRESCRITO
// pelo job de reconstrucao como ultimo commit da branch de ambiente. Nao e uma
// variavel de ambiente porque a Vercel builda a partir do conteudo do commit
// que recebeu por push -- o job nao tem como injetar env var nesse build.
//
// Efeito colateral util: `git log --oneline hom` mostra o ambiente inteiro
// (main + N merges + 1 commit de manifesto) e `cat build-manifest.json` na
// branch conta a mesma historia que o /version.
import rawManifest from '../build-manifest.json';

/**
 * Posicao do PR na ordem de montagem. Ausente = 0 = normal; 1 = `priority:high`.
 *
 * A chave e OMITIDA quando e 0 de proposito: um conjunto sem prioridade nenhuma
 * produz um manifesto identico ao de antes da feature existir, e a comparacao
 * de conjunto do assemble-env.sh continua dando no-op em vez de republicar tudo
 * uma vez so porque um campo novo apareceu.
 *
 * E um numero, e nao um booleano, para que um terceiro nivel (`priority:critical`
 * = 2) seja uma linha de jq no assemble-env.sh, sem migrar manifesto publicado.
 */
export type Priority = number;

export interface FeatureRef {
  /** Numero do PR que trouxe a feature. */
  pr: number;
  branch: string;
  /** SHA do tip da branch de feature no momento da montagem. */
  sha: string;
  author: string;
  priority?: Priority;
  /**
   * Arquivos que so mergearam porque uma resolucao gravada (git rerere) foi
   * aplicada. Presente = esta feature CONFLITA com outra do conjunto e entrou
   * mesmo assim.
   *
   * Ausente quando vazia, pelo mesmo motivo de `priority`: um conjunto sem
   * resolucao nenhuma produz um descritor byte a byte igual ao de antes desta
   * feature existir, e o teste de "nada mudou" continua dando no-op.
   *
   * O que ele NAO significa: que o codigo resolvido esta em algum PR. Ele nao
   * esta em lugar nenhum alem da montagem deste ambiente -- e por isso que o
   * comentario do notify.sh existe.
   */
  resolvedBy?: string[];
  /** PR com o qual esta feature conflita, quando entrou por resolucao. */
  conflictsWith?: number | null;
}

export interface ExcludedRef {
  pr: number;
  branch: string;
  author: string;
  /** Por enquanto sempre "conflict" -- o job nao exclui por nenhum outro motivo. */
  reason: string;
  /** PR contra o qual o merge conflitou (o que ja estava no conjunto). */
  conflictsWith: number | null;
  /** Saida de `git diff --name-only --diff-filter=U`. */
  files: string[];
  /**
   * Um PR pode ser prioritario e AINDA ASSIM ficar de fora: prioridade decide
   * ordem, nao resolve conflito. Uma branch atrasada em relacao a main conflita
   * sozinha e sai, com ou sem a label.
   */
  priority?: Priority;
}

export interface BuildManifest {
  /** "dev" | "hom" | "main" | "local" */
  environment: string;
  base: { branch: string; sha: string };
  /**
   * SHA da branch de ambiente que este build substituiu (null na primeira
   * publicacao e na main).
   *
   * Existe por dois motivos. O primeiro e auditoria: a branch passa a dizer de
   * onde veio. O segundo e menos obvio e mais importante -- como a montagem e
   * deterministica, voltar a um conjunto ja publicado reproduziria o commit
   * byte a byte, e um provedor que deduplica deploy por SHA (a Vercel faz)
   * ignoraria o push sem mover o alias da branch: a URL ficaria servindo um
   * conjunto antigo, silenciosamente. Este campo torna cada transicao unica.
   */
  previousEnvHead: string | null;
  /**
   * De onde vieram as resolucoes aplicadas nesta montagem.
   *
   * Ausente quando nenhuma feature dependeu de resolucao -- os dois lados dessa
   * condicao sao necessarios (ver a secao 6 do assemble-env.sh): presente,
   * regravar a resolucao do mesmo par republica o ambiente; ausente, gravar uma
   * resolucao para um par que nao esta aqui nao republica nada.
   */
  resolutions?: { ref: string; sha: string };
  features: FeatureRef[];
  excluded: ExcludedRef[];
}

export function loadManifest(): BuildManifest {
  return rawManifest as BuildManifest;
}

/**
 * A linha que a plateia le no browser: "main + feat/a + feat/c".
 * E o resumo mais curto possivel de "qual conjunto esta no ar".
 */
export function summarize(manifest: BuildManifest): string {
  const parts = [manifest.base.branch, ...manifest.features.map((f) => f.branch)];
  return parts.join(' + ');
}

/**
 * As features que so estao no ar por causa de uma resolucao gravada.
 *
 * O /version expoe isso separado porque e a unica coisa neste build que nao
 * corresponde a nenhum PR: o resto do ambiente e reproduzivel abrindo os PRs
 * listados em `features`.
 */
export function resolvedFeatures(manifest: BuildManifest): FeatureRef[] {
  return manifest.features.filter((f) => (f.resolvedBy?.length ?? 0) > 0);
}
