export type RendererBridgeContractErrorCode =
  "identity_mismatch" | "revision_mismatch" | "invalid_response";

export class RendererBridgeContractError extends Error {
  readonly code: RendererBridgeContractErrorCode;

  constructor(code: RendererBridgeContractErrorCode, diagnostic: string) {
    super(`Renderer Bridge contract failed: ${diagnostic}`);
    this.name = "RendererBridgeContractError";
    this.code = code;
  }
}
