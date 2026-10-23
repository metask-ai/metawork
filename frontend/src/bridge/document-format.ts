// Display routing only. Host inspects the actual container before admission.
export const isDocumentPreviewFile = (path: string) =>
  /\.(docx|xlsx|pptx|pdf)$/i.test(path);
