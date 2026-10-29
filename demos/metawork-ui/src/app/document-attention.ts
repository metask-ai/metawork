export type AttentionDocument = Pick<Document, "visibilityState" | "hasFocus">;

export function documentHasAttention(documentValue: AttentionDocument) {
  return (
    documentValue.visibilityState === "visible" && documentValue.hasFocus()
  );
}

export function subscribeDocumentAttention(
  documentValue: Document,
  windowValue: Window,
  onChange: (attention: boolean) => void,
) {
  const publish = () => onChange(documentHasAttention(documentValue));
  documentValue.addEventListener("visibilitychange", publish);
  windowValue.addEventListener("focus", publish);
  windowValue.addEventListener("blur", publish);
  publish();
  return () => {
    documentValue.removeEventListener("visibilitychange", publish);
    windowValue.removeEventListener("focus", publish);
    windowValue.removeEventListener("blur", publish);
  };
}
