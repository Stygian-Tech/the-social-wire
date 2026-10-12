import { afterEach, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { renderToStaticMarkup } from "react-dom/server";
import { BlockDocumentRenderer, MarkdownBlockEditor, importMarkdownDocument, markdownCodeText, markdownHeadingText, parseMarkdownBlocks } from "@stygian/markdown-editor";

afterEach(cleanup);
function viewer(markdown: string) {
  const element = document.createElement("div");
  element.innerHTML = renderToStaticMarkup(<BlockDocumentRenderer document={importMarkdownDocument(markdown)} />);
  return element;
}
describe("vendored Markdown editor", () => {
  it("separates adjacent headings, rules, paragraphs, quotes and task lists without blank lines", () => {
    const source = "# First\nParagraph\n## Second ##\n---\n- [x] Done\n  - Nested\n> Quote\nAfter";
    const blocks = parseMarkdownBlocks(source);
    expect(blocks.map(block => block.kind)).toEqual(["heading", "paragraph", "heading", "thematic-break", "unordered-list", "unordered-list", "quote", "paragraph"]);
    expect(blocks[4].source).toBe("- [x] Done");
    const element = viewer(source);
    expect(element.querySelector("h1")?.textContent).toBe("First");
    expect(element.querySelector("h2")?.textContent).toBe("Second");
    expect(element.querySelector("hr")).not.toBeNull();
    expect(element.querySelector("blockquote")?.textContent).toBe("Quote");
    expect(element.querySelector('li > [role="checkbox"]')?.getAttribute("aria-checked")).toBe("true");
    expect(element.querySelector("ul > li > ul > li")?.textContent).toBe("Nested");
  });
  it("recognizes setext headings and preserves raw heading source", () => {
    const source = "Multiline\nHeading\n=======\nFollowing\n\nSecond\n---\n\n---";
    const blocks = parseMarkdownBlocks(source);
    expect(blocks.map(block => block.kind)).toEqual(["heading", "paragraph", "heading", "thematic-break"]);
    expect(blocks[0].source).toBe("Multiline\nHeading\n=======");
    expect(markdownHeadingText(blocks[0].source)).toBe("Multiline\nHeading");
    const element = viewer(source);
    expect(element.querySelector("h1")?.textContent).toBe("MultilineHeading");
    expect(element.querySelector("h2")?.textContent).toBe("Second");
    expect(element.querySelectorAll("hr").length).toBe(1);
  });
  it("keeps tilde, longer and unterminated fenced content literal", () => {
    const source = "~~~~ts\n# Literal heading\n---\n- Literal list\n~~~~\nAfter\n\n````js\n```inner\n````\n\n~~~\nUnclosed";
    const blocks = parseMarkdownBlocks(source);
    expect(blocks.map(block => block.kind)).toEqual(["code", "paragraph", "code", "code"]);
    expect(markdownCodeText(blocks[0].source)).toBe("# Literal heading\n---\n- Literal list");
    expect(markdownCodeText(blocks[2].source)).toBe("```inner");
    expect(markdownCodeText(blocks[3].source)).toBe("Unclosed");
    const element = viewer(source);
    expect(element.querySelectorAll("pre").length).toBe(3);
    expect(element.querySelectorAll("h1, hr, ul").length).toBe(0);
  });
  it("renders semantic nested mixed lists and preserves top-level numbered starts", () => {
    const element = viewer("3. First\n  - Child\n    5. Grandchild\n  - Second Child\n4. Second\n- A Bullet\n- Another Bullet");
    expect(element.querySelector("ol")?.getAttribute("start")).toBe("3");
    expect(element.querySelectorAll("div.typeset > ol > li").length).toBe(2);
    expect(element.querySelectorAll("ol > li > ul > li").length).toBe(2);
    expect(element.querySelector("ol > li > ul > li > ol")?.getAttribute("start")).toBe("5");
    expect(element.querySelectorAll("div.typeset > ul > li").length).toBe(2);
    expect(element.querySelectorAll("ul > ul, ol > ul, ul > ol").length).toBe(0);
  });
  it("renders all six semantic heading levels and escapes HTML/unsafe links", () => {
    const element = viewer("# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n<script>alert(1)</script> [bad](javascript:alert)");
    for (let level = 1; level <= 6; level++) expect(element.querySelector(`h${level}`)).not.toBeNull();
    expect(element.querySelector("script, a")).toBeNull();
    expect(element.textContent).toContain("<script>alert(1)</script> bad");
  });
  it("does not emit or normalize source when a focused unchanged block blurs", () => {
    const source = "\n# Heading  \n\n\nParagraph with trailing spaces  \n";
    const change = mock(() => {});
    const result = render(<MarkdownBlockEditor value={source} onChange={change} />);
    fireEvent.click(screen.getAllByTestId("markdown-block-preview")[1]);
    fireEvent.blur(screen.getByTestId("markdown-block-textarea"));
    expect(change).not.toHaveBeenCalled();
    result.unmount();
    render(<MarkdownBlockEditor value={source} onChange={change} />);
    expect(change).not.toHaveBeenCalled();
  });
  it("synchronizes externally selected draft Markdown without writing stale source", () => {
    const change = mock(() => {});
    const result = render(<MarkdownBlockEditor value="First Draft" onChange={change} />);
    fireEvent.click(screen.getByTestId("markdown-block-preview"));
    result.rerender(<MarkdownBlockEditor value={"# Second Draft\nNew body"} onChange={change} />);
    expect(screen.queryByTestId("markdown-block-textarea")).toBeNull();
    expect(screen.queryByText("First Draft")).toBeNull();
    expect(screen.getByRole("heading", { name: "Second Draft" })).toBeDefined();
    expect(screen.getByText("New body")).toBeDefined();
    expect(change).not.toHaveBeenCalled();
  });
  it("lets viewer paragraph/list/embed links navigate while editor previews suppress navigation", () => {
    const source = "[Paragraph](https://example.com/paragraph)\n\n- [List](https://example.com/list)\n\n@[embed](https://example.com/embed)";
    const checkClick = (anchor: Element) => {
      let prevented: boolean | undefined;
      // Observe after React handles the click, then suppress jsdom navigation only.
      const observe = (event: Event) => { prevented = event.defaultPrevented; event.preventDefault(); };
      window.addEventListener("click", observe, { once: true });
      fireEvent.click(anchor);
      return prevented;
    };
    const result = render(<BlockDocumentRenderer document={importMarkdownDocument(source)} />);
    for (const anchor of result.container.querySelectorAll("a")) expect(checkClick(anchor)).toBe(false);
    result.unmount();
    const editor = render(<MarkdownBlockEditor value={source} onChange={() => {}} />);
    expect(checkClick(editor.container.querySelector("a")!)).toBe(true);
  });
});
