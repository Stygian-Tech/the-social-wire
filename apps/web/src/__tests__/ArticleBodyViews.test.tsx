import { afterAll, afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { useRef, useState } from "react";
import type { BlockEditorHandle } from "@stygian/markdown-editor";
import { ArticleBodyViews, type ArticleBodyMode } from "@/components/Articles/ArticleBodyViews";

const globals = ["requestAnimationFrame", "cancelAnimationFrame", "getComputedStyle"] as const;
const descriptors = globals.map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)] as const);
beforeAll(() => {
  Object.defineProperty(globalThis, "requestAnimationFrame", { configurable: true, value: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0) });
  Object.defineProperty(globalThis, "cancelAnimationFrame", { configurable: true, value: (handle: ReturnType<typeof setTimeout>) => clearTimeout(handle) });
  Object.defineProperty(globalThis, "getComputedStyle", { configurable: true, value: window.getComputedStyle.bind(window) });
});
afterAll(() => { for (const [name, descriptor] of descriptors) { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); } });
afterEach(cleanup);

const source = "# Title\n## This Is Nice\n---\nA **bold** paragraph.\n- Here's a list\n- It's not bad\n  - This is another list item\n- More list stuff\n\n---\n## Here's Another Heading\n";
function Fixture({ id = "one", value = source, readOnly = false }: { id?: string; value?: string; readOnly?: boolean }) {
  const ref = useRef<BlockEditorHandle>(null);
  const [markdown, setMarkdown] = useState(value);
  const [mode, setMode] = useState<ArticleBodyMode>("editor");
  return <ArticleBodyViews draftId={id} markdown={markdown} mode={mode} onModeChange={setMode} onChange={setMarkdown} editorRef={ref} resolveImageURL={() => undefined} onImageFiles={async () => {}} readOnly={readOnly} />;
}

describe("Article views", () => {
  it("switches among the real editor, exact Markdown source, and formatted article", () => {
    render(<Fixture />);
    expect(screen.getByRole("heading", { level: 1, name: "Title" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Editor" }).getAttribute("aria-pressed")).toBe("true");
    fireEvent.click(screen.getByRole("button", { name: "Markdown" }));
    const input = screen.getByLabelText("Article Markdown") as HTMLTextAreaElement;
    expect(input.value).toBe(source);
    const changed = source.replace("This Is Nice", "Updated Heading");
    fireEvent.change(input, { target: { value: changed } });
    fireEvent.click(screen.getByRole("button", { name: "Article Viewer" }));
    const article = screen.getByRole("article", { name: "Article Viewer" });
    expect(within(article).getByRole("heading", { level: 2, name: "Updated Heading" })).toBeTruthy();
    expect(within(article).getAllByRole("separator")).toHaveLength(2);
    expect(article.querySelector("strong")?.textContent).toBe("bold");
    expect(article.querySelector("li ul li")?.textContent).toContain("This is another list item");
    fireEvent.click(screen.getByRole("button", { name: "Editor" }));
    expect(screen.getByRole("heading", { name: "Updated Heading" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Markdown" }));
    expect((screen.getByLabelText("Article Markdown") as HTMLTextAreaElement).value).toBe(changed);
  });
  it("does not rewrite untouched source when a focused block blurs before switching", () => {
    const exact = "# Heading\n\n\nParagraph with trailing space.  \n\n";
    render(<Fixture value={exact} />);
    fireEvent.click(screen.getByText("Paragraph with trailing space."));
    const editing = screen.getAllByRole("textbox")[0]!;
    fireEvent.blur(editing);
    fireEvent.click(screen.getByRole("button", { name: "Markdown" }));
    expect((screen.getByLabelText("Article Markdown") as HTMLTextAreaElement).value).toBe(exact);
  });
  it("resets the editor when selecting a different draft and writes to the new body", () => {
    const change = mock(() => {});
    const ref = { current: null };
    const common = { mode: "editor" as const, onModeChange: () => {}, onChange: change, editorRef: ref, resolveImageURL: () => undefined, onImageFiles: async () => {}, readOnly: false };
    const view = render(<ArticleBodyViews {...common} draftId="one" markdown="# First Draft" />);
    view.rerender(<ArticleBodyViews {...common} draftId="two" markdown="# Second Draft" />);
    expect(screen.queryByText("First Draft")).toBeNull();
    fireEvent.click(screen.getByText("Second Draft"));
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "# Changed Second Draft" } });
    expect(change).toHaveBeenLastCalledWith("# Changed Second Draft");
  });
  it("keeps published source read-only while the article viewer remains interactive", () => {
    render(<Fixture readOnly value="[Read More](https://example.com/article)" />);
    fireEvent.click(screen.getByRole("button", { name: "Markdown" }));
    expect((screen.getByLabelText("Article Markdown") as HTMLTextAreaElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Article Viewer" }));
    const article = screen.getByRole("article", { name: "Article Viewer" });
    expect(within(article).getByRole("link", { name: "Read More" }).getAttribute("href")).toBe("https://example.com/article");
    expect(article.closest("[inert]")).toBeNull();
  });
  it("holds the current mode while image insertion or another draft action is in progress", () => {
    const changeMode = mock(() => {});
    render(<ArticleBodyViews draftId="one" markdown="# Draft" mode="editor" onModeChange={changeMode} onChange={() => {}} editorRef={{ current: null }} resolveImageURL={() => undefined} onImageFiles={async () => {}} readOnly busy />);
    for (const name of ["Editor", "Markdown", "Article Viewer"]) expect((screen.getByRole("button", { name }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Markdown" }));
    expect(changeMode).not.toHaveBeenCalled();
  });
});
