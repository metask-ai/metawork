import type { ModelMetadata } from "../../bridge/contracts.ts";

/** A model the user has declared nothing about: every field unknown. */
export function emptyModelMetadata(): ModelMetadata {
  return {
    maxInputTokens: null,
    maxOutputTokens: null,
    capabilities: {
      textInput: null,
      audioInput: null,
      videoInput: null,
      output: {
        text: null,
        image: null,
        audio: null,
        video: null,
        embedding: null,
      },
      imageInput: null,
      pdfInput: null,
      batch: null,
      citations: null,
      codeExecution: null,
      structuredOutputs: null,
      thinking: { supported: null, adaptive: null, enabled: null },
      effort: {
        supported: null,
        low: null,
        medium: null,
        high: null,
        max: null,
      },
      contextManagement: {
        supported: null,
        clearThinking20251015: null,
        clearToolUses20250919: null,
        compact20260112: null,
      },
    },
  };
}

/**
 * The whole declaration a replacement must carry: a model replace is not a
 * patch, so everything but the image input comes from `base` as it is.
 */
export function declareImageInput(
  base: ModelMetadata | undefined,
  imageInput: boolean | null,
): ModelMetadata {
  const metadata = structuredClone(base ?? emptyModelMetadata());
  metadata.capabilities.imageInput = imageInput;
  return metadata;
}
