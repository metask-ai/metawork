const tags = new Set(
  "a abbr article aside b blockquote br caption code col colgroup dd del div dl dt em figcaption figure footer h1 h2 h3 h4 h5 h6 header hr i img kbd li main mark nav ol p pre s samp section small span strong sub sup table tbody td th thead tfoot time tr u ul var".split(
    " ",
  ),
);
const attributes = new Set(
  "alt colspan dir height lang rowspan scope span title width".split(" "),
);
const rasterImage =
  /^data:image\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/i;
const policy =
  "default-src 'none'; img-src data:; base-uri 'none'; form-action 'none'";

export function staticHtmlPreview(source: string): string {
  // Template contents stay inert while parsing and filtering the workspace file.
  const template = document.createElement("template");
  template.innerHTML = source;
  for (const element of template.content.querySelectorAll("*")) {
    if (
      element.namespaceURI !== "http://www.w3.org/1999/xhtml" ||
      !tags.has(element.localName)
    ) {
      element.remove();
      continue;
    }
    for (const attribute of Array.from(element.attributes)) {
      if (attributes.has(attribute.name)) continue;
      if (
        element.localName === "img" &&
        attribute.name === "src" &&
        rasterImage.test(attribute.value)
      )
        continue;
      element.removeAttribute(attribute.name);
    }
  }
  return `<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${policy}"><body>${template.innerHTML}</body>`;
}
