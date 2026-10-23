// Synthetic inputs generated before measurement; never user document content.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { Document, Packer, PageBreak, Paragraph } from "docx";
import pptxgen from "pptxgenjs";
import { readOfficeComponent } from "./office-environment.mjs";

if (process.argv.length !== 4)
  throw Error(
    "Usage: create-office-preview-performance-fixtures.mjs <component> <empty-output-directory>",
  );
const component = readOfficeComponent(path.resolve(process.argv[2]));
const directory = path.resolve(process.argv[3]);
mkdirSync(directory, { recursive: false });
for (const [name, count] of [
  ["pages.docx", 24],
  ["cancel.docx", 180],
]) {
  const document = new Document({
    sections: [
      {
        children: Array.from({ length: count }, (_, index) => [
          new Paragraph(`Performance page ${index + 1} 中文业务文档`),
          ...Array.from(
            { length: 8 },
            (_, row) =>
              new Paragraph(
                `第 ${row + 1} 行：固定输入、分页检查、无外部资源。`,
              ),
          ),
          ...(index + 1 < count
            ? [new Paragraph({ children: [new PageBreak()] })]
            : []),
        ]).flat(),
      },
    ],
  });
  writeFileSync(path.join(directory, name), await Packer.toBuffer(document), {
    flag: "wx",
  });
}
const presentation = new pptxgen();
presentation.layout = "LAYOUT_WIDE";
for (let index = 0; index < 12; index++) {
  const slide = presentation.addSlide();
  slide.addText(`第 ${index + 1} 页 Business review`, {
    x: 1,
    y: 1,
    w: 11,
    h: 1,
    fontSize: 28,
  });
  slide.addText("Synthetic Chinese / English performance fixture", {
    x: 1,
    y: 3,
    w: 11,
    h: 2,
    fontSize: 20,
  });
}
await presentation.writeFile({ fileName: path.join(directory, "slides.pptx") });
const run = (args) =>
  execFileSync(component.entry, args, {
    timeout: 150000,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
run([
  "python",
  "-c",
  `
from openpyxl import Workbook
from openpyxl.chart import BarChart, Reference
import sys
w=Workbook();s=w.active;s.title='业务 Data'
for row in range(1,1001):
    s.append([row*100+col for col in range(1,31)])
s['A1']='中文业务';s['B1']='=SUM(B2:B40)'
s.print_area='A1:H42';s.page_setup.orientation='landscape'
s.page_setup.fitToWidth=1;s.page_setup.fitToHeight=1
s.sheet_properties.pageSetUpPr.fitToPage=True
c=BarChart();c.title='Saved values';c.add_data(Reference(s,min_col=3,max_col=4,min_row=1,max_row=8));s.add_chart(c,'J2')
h=w.create_sheet('Hidden');h['A1']='Hidden cell';h.sheet_state='hidden'
w.save(sys.argv[1]);w.close()
`,
  path.join(directory, "dense.xlsx"),
]);
run([
  "pdf",
  path.join(directory, "pages.docx"),
  path.join(directory, "pages.pdf"),
]);
console.log(
  JSON.stringify({
    directory,
    docxPages: 24,
    slides: 12,
    workbookCells: 30001,
  }),
);
