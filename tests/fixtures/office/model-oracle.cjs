// Synthetic complete input for the independent model-task business oracle.
const fs = require("node:fs");
const PptxGenJS = require("pptxgenjs");

(async () => {
  const output = process.argv[2];
  if (!output || fs.existsSync(output)) throw new Error("Fresh output required");
  const deck = new PptxGenJS();
  const first = deck.addSlide();
  first.addText("销售汇总", { x: 1, y: 0.2, w: 8, h: 0.5 });
  first.addText("总额650", { x: 1, y: 1, w: 8, h: 0.5 });
  first.addNotes("验收备注：650");
  for (const [kind, title] of [["bar", "地区金额"], ["line", "地区趋势"]]) {
    const slide = deck.addSlide();
    slide.addText(title, { x: 1, y: 0.2, w: 8, h: 0.5 });
    slide.addChart(deck.ChartType[kind],
      [{ name: "Amount", labels: ["North", "South"], values: [300, 350] }],
      { x: 1, y: 1, w: 8, h: 4, barDir: "col", showValue: true,
        chartColors: ["0D9488", "14B8A6"], lineDataSymbol: "circle",
        lineDataSymbolSize: 8 });
  }
  await deck.writeFile({ fileName: output });
})().catch((error) => { console.error(error); process.exitCode = 1; });
