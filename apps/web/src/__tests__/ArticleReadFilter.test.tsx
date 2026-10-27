import { afterEach, expect, it, mock } from "bun:test";
import { cleanup, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { ArticleReadFilter } from "@/components/FeedHeader/ArticleReadFilter";

afterEach(cleanup);

it("announces the selected filter as a pressed button and changes it by keyboard", async () => {
  const change = mock(() => {});
  const view = render(<ArticleReadFilter value="all" onChange={change} />);
  const group = screen.getByRole("group", { name: "Articles Filter" });
  const all = within(group).getByRole("button", { name: "All", pressed: true });
  const unread = within(group).getByRole("button", { name: "Unread", pressed: false });
  expect(all.tabIndex).toBe(0);
  expect(unread.tabIndex).toBe(0);
  unread.focus();
  await userEvent.setup({ document }).keyboard("{Enter}");
  expect(change).toHaveBeenCalledWith("unread");
  view.rerender(<ArticleReadFilter value="unread" onChange={change} />);
  expect(within(group).getByRole("button", { name: "Unread", pressed: true })).toBe(unread);
  expect(document.activeElement).toBe(unread);
  expect(within(group).queryByRole("tab")).toBeNull();
});
