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

export interface FeatureRef {
  /** Numero do PR que trouxe a feature. */
  pr: number;
  branch: string;
  /** SHA do tip da branch de feature no momento da montagem. */
  sha: string;
  author: string;
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
