import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import {
  Document,
  Header,
  Packer,
  PageBreak,
  Paragraph,
  Table,
  TableCell,
  TableRow,
  TextRun,
  WidthType,
} from "docx";
import pptxgen from "pptxgenjs";

const directory = path.resolve(process.argv[2]);
mkdirSync(directory, { recursive: true });
const paragraph = (text) => new Paragraph(text);
const row = (text) =>
  new TableRow({
    children: [new TableCell({ children: [paragraph(text)] })],
  });
const document = new Document({
  sections: [
    {
      headers: {
        default: new Header({ children: [paragraph("Header original")] }),
      },
      children: [
        new Paragraph({
          children: [
            new TextRun({ text: "Windows Office 中文验收", bold: true }),
          ],
        }),
        paragraph("Keep delete insert."),
        paragraph("Paragraph A"),
        paragraph("Paragraph B"),
        new Table({
          width: { size: 9000, type: WidthType.DXA },
          columnWidths: [9000],
          rows: [
            row("Before table revision"),
            row("Removed row"),
            row("Added row"),
          ],
        }),
        new Paragraph({ children: [new PageBreak()] }),
        paragraph("第二页 Page two"),
      ],
    },
  ],
});
writeFileSync(
  path.join(directory, "original.docx"),
  await Packer.toBuffer(document),
);

// A long real document keeps the real engine alive long enough to obtain
// process handles before testing cancellation. No injected sleep in the engine.
const long = new Document({
  sections: [
    {
      children: Array.from({ length: 180 }, (_, index) => [
        paragraph(`Cancellation page ${index + 1} 生命周期`),
        ...(index === 179
          ? []
          : [new Paragraph({ children: [new PageBreak()] })]),
      ]).flat(),
    },
  ],
});
writeFileSync(path.join(directory, "long.docx"), await Packer.toBuffer(long));

const presentation = new pptxgen();
presentation.layout = "LAYOUT_WIDE";
for (const text of ["第一页 First slide", "第二页 Second slide"]) {
  const slide = presentation.addSlide();
  slide.addText(text, {
    x: 1,
    y: 1,
    w: 11,
    h: 2,
    fontFace: "Microsoft YaHei",
    fontSize: 30,
    color: "222222",
  });
}
await presentation.writeFile({ fileName: path.join(directory, "sample.pptx") });
