import assert from "node:assert/strict";
import test from "node:test";

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

const vite = await createServer({
  root: "frontend",
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});

const { Markdown, renderMarkdownForClipboard } = await vite.ssrLoadModule(
  "/src/components/ai/Markdown.tsx",
);

test.after(async () => {
  await vite.close();
});

function render(markdown) {
  return renderToStaticMarkup(createElement(Markdown, null, markdown));
}

// The release CSP is `style-src 'self'` with no 'unsafe-inline', so an inline
// style attribute would be dropped by the WebView and the formula would be
// laid out wrong. KaTeX's MathML carries spacing in attributes instead and
// needs none. The leading space keeps this off `displaystyle="…"`, which is a
// MathML attribute and not a style at all.
function assertNoInlineStyle(markup) {
  assert.doesNotMatch(markup, /\sstyle="/);
}

const issueProduct = String.raw`$$\text{CPU 时间} = \text{指令数} \times \text{CPI} \times \text{时钟周期}$$`;
const issueQuotient = String.raw`$$\text{CPU 时间} = \frac{\text{指令数} \times \text{CPI}}{\text{时钟频率}}$$`;

test("renders the reported formulas as MathML without inline style", () => {
  for (const source of [issueProduct, issueQuotient]) {
    const markup = render(source);
    assert.match(markup, /<math /);
    assert.match(markup, /display="block"/);
    // KaTeX writes the space inside a text group as a non-breaking space.
    assert.match(markup, /<mtext>CPU\s时间<\/mtext>/u);
    assert.match(markup, /<mo>×<\/mo>/);
    // The LaTeX survives only in the MathML annotation, which carries the
    // source for assistive technology and is not rendered.
    assert.match(markup, /<annotation encoding="application\/x-tex">/);
    assertNoInlineStyle(markup);
  }
  assert.match(render(issueQuotient), /<mfrac>/);
});

test("a formula on its own line is display math, one in a sentence is not", () => {
  const own = render("$$x+1$$");
  assert.match(own, /<math [^>]*display="block"/);

  const inSentence = render("the value $$x+1$$ holds");
  assert.match(inSentence, /<math /);
  assert.doesNotMatch(inSentence, /display="block"/);
  assert.match(inSentence, /the value/);
  assert.match(inSentence, /holds/);
});

test("a fenced block formula renders as display math", () => {
  const markup = render("$$\n\\frac{a}{b}\n$$");
  assert.match(markup, /<math [^>]*display="block"/);
  assert.match(markup, /<mfrac>/);
  assertNoInlineStyle(markup);
});

test("an unterminated formula shows its source, not an error or a blank", () => {
  const markup = render("formula:\n\n$$\\frac{a}{b");
  assert.doesNotMatch(markup, /<math/);
  assert.doesNotMatch(markup, /katex-error/);
  assert.match(markup, /\$\$\\frac\{a\}\{b/);
  assertNoInlineStyle(markup);

  // micromark reads the opening line of an unterminated block as the fence's
  // meta and leaves the parsed value empty, so the text can only come from the
  // recorded source positions.
  const opener = render("start\n\n$$");
  assert.match(opener, /\$\$/);
  assert.doesNotMatch(opener, /<math/);
});

test("a formula arriving byte by byte never flickers through error or blank", () => {
  const complete = String.raw`$$\frac{a}{b}$$`;
  for (let length = 1; length <= complete.length; length += 1) {
    const prefix = complete.slice(0, length);
    const markup = render(prefix);
    assertNoInlineStyle(markup);
    assert.doesNotMatch(markup, /katex-error/, `prefix ${prefix}`);
    if (length === complete.length) {
      assert.match(markup, /<math /, `prefix ${prefix}`);
      continue;
    }
    // Until the closing run arrives the prefix is its own source text, and the
    // dollars the author already typed stay visible.
    assert.doesNotMatch(markup, /<math/, `prefix ${prefix}`);
    assert.match(markup, /\$/, `prefix ${prefix}`);
  }
});

test("dollars in code and in prose amounts are not formulas", () => {
  const fence = render("```\n$$x$$\n```");
  assert.doesNotMatch(fence, /<math/);
  assert.match(fence, /\$\$x\$\$/);

  const inline = render("see `$$x$$` here");
  assert.doesNotMatch(inline, /<math/);
  assert.match(inline, /<code>\$\$x\$\$<\/code>/);

  // Single-dollar text math is disabled: an amount is prose, not a formula.
  const amounts = render("it costs $5 and $7 today");
  assert.doesNotMatch(amounts, /<math/);
  assert.match(amounts, /it costs \$5 and \$7 today/);
});

test("untrusted commands never reach the document", () => {
  const markup = render(String.raw`$$\href{https://evil.example}{click}$$`);
  assert.doesNotMatch(markup, /href=/);
  // The command falls back to visible text rather than being applied.
  assert.match(markup, /\\href/);
  assertNoInlineStyle(markup);
});

test("an unknown command renders as its own visible source", () => {
  // KaTeX marks it with the MathML mathcolor attribute rather than a style, so
  // it stays visible under the release CSP instead of silently disappearing.
  const markup = render(String.raw`$$\notacommand{x}$$`);
  assert.match(markup, /<mtext>\\notacommand<\/mtext>/);
  assert.doesNotMatch(markup, /katex-error/);
  assertNoInlineStyle(markup);
});

test("a formula KaTeX cannot parse falls back to its delimited source", () => {
  // Terminated, so the streaming guard passes it on, but the braces are
  // unbalanced and KaTeX raises a parse error.
  const markup = render(String.raw`$$\frac{a}{b$$`);
  assert.doesNotMatch(markup, /katex-error/);
  assert.doesNotMatch(markup, /<math/);
  assert.match(markup, /\$\$\\frac\{a\}\{b\$\$/);
  assertNoInlineStyle(markup);
});

test("a macro expansion bomb is bounded, not run", () => {
  // Reachable from every source this renderer accepts, so it is bounded by
  // configuration rather than by trusting the author.
  for (const bomb of [
    String.raw`$$\def\a{\a\a}\a$$`,
    String.raw`$$\def\x{\x}\x$$`,
  ]) {
    const started = Date.now();
    const markup = render(bomb);
    assert.ok(
      Date.now() - started < 2000,
      `expansion was not bounded: ${bomb}`,
    );
    assert.doesNotMatch(markup, /<math/);
    assert.match(markup, /\\def/);
    assertNoInlineStyle(markup);
  }
});

test("tabular constructs keep their spacing in attributes, not styles", () => {
  // These are the shapes that would need inline CSS in another engine; under
  // the release CSP that CSS would be dropped and the layout would collapse.
  const matrix = render(
    String.raw`$$\begin{pmatrix} a & b \\ c & d \end{pmatrix}$$`,
  );
  assert.match(matrix, /<mtable[^>]*columnspacing="/);
  assertNoInlineStyle(matrix);

  const aligned = render(
    String.raw`$$\begin{aligned} x &= 1 \\ y &= 2 \end{aligned}$$`,
  );
  assert.match(aligned, /<mtable/);
  assertNoInlineStyle(aligned);

  // `displaystyle` is a MathML attribute; it must not be read as a style.
  assert.match(matrix, /displaystyle="/);
});

test("a fenced math block renders as display math", () => {
  const markup = render("```math\n\\frac{a}{b}\n```");
  assert.match(markup, /<math [^>]*display="block"/);
  assert.match(markup, /<mfrac>/);
  assertNoInlineStyle(markup);
});

test("every Markdown caller gets math, not only Assistant output", () => {
  // One shared component serves Assistant output, the Skill page and the
  // workspace file preview, so each renders untrusted text from a different
  // owner through this same pipeline.
  const skillPage = renderToStaticMarkup(
    createElement(Markdown, { interactive: false }, issueQuotient),
  );
  assert.match(skillPage, /<mfrac>/);
  assertNoInlineStyle(skillPage);

  const filePreview = renderToStaticMarkup(
    createElement(Markdown, { textResourcesOnly: true }, issueQuotient),
  );
  assert.match(filePreview, /<mfrac>/);
  assertNoInlineStyle(filePreview);

  // The untrusted-input bounds hold on those paths too, not just the model's.
  for (const markup of [
    renderToStaticMarkup(
      createElement(
        Markdown,
        { interactive: false },
        String.raw`$$\href{https://evil.example}{x}$$`,
      ),
    ),
    renderToStaticMarkup(
      createElement(
        Markdown,
        { textResourcesOnly: true },
        String.raw`$$\includegraphics{x.png}$$`,
      ),
    ),
  ]) {
    assert.doesNotMatch(markup, /href=/);
    assert.doesNotMatch(markup, /<img/);
    assertNoInlineStyle(markup);
  }
});

test("math does not open a raw HTML path", () => {
  const markup = render("$$x$$\n\n<script>alert(1)</script>");
  assert.match(markup, /<math /);
  assert.doesNotMatch(markup, /<script>/);
});

test("clipboard HTML keeps the LaTeX source, not MathML", async () => {
  for (const source of [
    issueQuotient,
    String.raw`$$a \\ b$$`,
    "$$\n\\frac{a}{b}\n$$",
    "the value $$x+1$$ holds",
  ]) {
    const markup = await renderMarkdownForClipboard(source);
    assert.doesNotMatch(markup, /<math/);
    assert.doesNotMatch(markup, /katex/);
    for (const fragment of source.split("\n"))
      assert.ok(
        markup.includes(fragment),
        `clipboard markup lost ${JSON.stringify(fragment)}: ${markup}`,
      );
  }
});
