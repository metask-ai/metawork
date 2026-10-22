// Display routing only. Host inspects the actual container before admission.
export const isOfficeDocument = (path: string) =>
  /\.(docx|xlsx|pptx)$/i.test(path);
