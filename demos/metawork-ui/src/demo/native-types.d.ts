declare module "@native-sdk/cli" {
  export type NativeSdkJson =
    | null
    | boolean
    | number
    | string
    | NativeSdkJson[]
    | { [key: string]: NativeSdkJson };
  export type NativeSdkShortcutDetail = { id: string };
}
interface Window {
  zero?: {
    invoke(
      command: string,
      payload: import("@native-sdk/cli").NativeSdkJson,
    ): Promise<unknown>;
    on(
      event: "drop:files",
      listener: (value: { paths: string[] }) => void,
    ): () => void;
    on<T = unknown>(event: string, listener: (value: T) => void): () => void;
  };
}
