// Synthetic qualification inputs; resolved only through the fixed private Node entry.
const fs = require("node:fs");
const path = require("node:path");
const PptxGenJS = require("pptxgenjs");
const {
  Document,
  Packer,
  Paragraph,
  Table,
  TableRow,
  TableCell,
} = require("docx");
function version(name) {
  let directory = path.dirname(require.resolve(name));
  for (let depth = 0; depth < 4; depth++) {
    const manifest = path.join(directory, "package.json");
    if (fs.existsSync(manifest)) {
      const metadata = JSON.parse(fs.readFileSync(manifest, "utf8"));
      if (metadata.name === name) return metadata.version;
    }
    directory = path.dirname(directory);
  }
  throw new Error("Installed generator identity unavailable");
}
(async () => {
  const output = process.argv[2];
  fs.mkdirSync(output, { recursive: true });
  const document = new Document({
    sections: [
      {
        children: [
          new Paragraph("Office 中文验收"),
          new Paragraph("Original paragraph"),
          new Table({
            rows: [
              new TableRow({
                children: [
                  new TableCell({ children: [new Paragraph("地区")] }),
                  new TableCell({ children: [new Paragraph("金额")] }),
                ],
              }),
              new TableRow({
                children: [
                  new TableCell({ children: [new Paragraph("华东")] }),
                  new TableCell({ children: [new Paragraph("300")] }),
                ],
              }),
            ],
          }),
        ],
      },
    ],
  });
  fs.writeFileSync(
    path.join(output, "paragraph-table.docx"),
    await Packer.toBuffer(document),
  );
  for (const notes of [false, true]) {
    const deck = new PptxGenJS();
    const slide = deck.addSlide();
    slide.addText("Office 中文验收", { x: 1, y: 0.2, w: 8, h: 0.5 });
    if (notes) slide.addNotes("Notes: total 650");
    await deck.writeFile({
      fileName: path.join(output, notes ? "text-notes.pptx" : "text.pptx"),
    });
  }
  for (const type of ["bar", "bar-horizontal", "line"])
    for (const multicolor of [false, true])
      for (const labels of [false, true]) {
        const deck = new PptxGenJS();
        const slide = deck.addSlide();
        slide.addText("Independent chart qualification", {
          x: 1,
          y: 0.2,
          w: 8,
          h: 0.5,
        });
        const options = {
          x: 1,
          y: 1,
          w: 8,
          h: 4,
          barDir: type === "bar-horizontal" ? "bar" : "col",
          showValue: labels,
          showLegend: false,
        };
        if (multicolor) options.chartColors = ["0D9488", "14B8A6"];
        slide.addChart(
          deck.ChartType[type === "bar-horizontal" ? "bar" : type],
          [{ name: "Amount", labels: ["North", "South"], values: [300, 350] }],
          options,
        );
        await deck.writeFile({
          fileName: path.join(
            output,
            `${type}-${multicolor ? "multi" : "default"}-${labels ? "labels" : "no-labels"}.pptx`,
          ),
        });
      }
  console.log(
    JSON.stringify({
      node: process.version,
      pptxgenjs: new PptxGenJS().version,
      docx: version("docx"),
    }),
  );
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
