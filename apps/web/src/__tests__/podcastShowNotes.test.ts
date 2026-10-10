import { expect, it } from "bun:test";
import { linkPodcastTimecodes, parsePodcastTimecode, podcastNotesExcerpt } from "@/lib/podcasts/showNotes";
import { sanitizeHTMLWithLinks } from "@/lib/sanitize";

it("parses minute and hour timecodes with episode duration bounds", () => {
  expect(parsePodcastTimecode("7:20")).toBe(440);
  expect(parsePodcastTimecode("01:02:03")).toBe(3723);
  expect(parsePodcastTimecode("90:00")).toBe(5400);
  expect(parsePodcastTimecode("0:00", 30)).toBe(0);
  expect(parsePodcastTimecode("0:30", 30)).toBe(30);
  for (const time of ["1:2", "1:60", "1:60:00", "-1:20", "1:20junk", "1:20:00:10", "https://test/1:20"]) expect(parsePodcastTimecode(time)).toBeNull();
  expect(parsePodcastTimecode("0:31", 30)).toBeNull();
});

it("links text timecodes and matching timestamp anchors without altering ordinary links or attributes", () => {
  const html = '<p title="0:20">0:00 Intro, 7:20 Topic, 1:01:00 Later. Invalid 7:80, 1:99:00, 0:31:00:01.</p><a href="https://publisher.test/?t=440">7:20</a><a href="#t=3723">1:02:03</a><a href="#0:20">0:20</a><a href="https://publisher.test/story">7:20</a><a href="https://publisher.test/story">Read about 7:20</a><a href="https://publisher.test/?t=50">7:20</a><code>7:20</code>';
  const root = document.createElement("div");
  root.innerHTML = linkPodcastTimecodes(html, 4000);
  expect([...root.querySelectorAll("button")].map(button => Number(button.dataset.podcastTimecode))).toEqual([0, 440, 3660, 440, 3723, 20]);
  expect(root.querySelector("p")?.getAttribute("title")).toBe("0:20");
  expect(root.querySelectorAll("a")).toHaveLength(3);
  expect(root.querySelector("code")?.textContent).toBe("7:20");
  expect(root.textContent).toContain("Invalid 7:80, 1:99:00, 0:31:00:01.");
});

it("keeps malformed links and out-of-range timestamps inert after sanitization", () => {
  const root = document.createElement("div");
  root.innerHTML = linkPodcastTimecodes(sanitizeHTMLWithLinks('<script>0:10</script><p onclick="bad()">0:20 0:40</p><a href="javascript:alert(1)">0:10</a><a href="https://[bad?t=10">0:10</a><a href="https://publisher.test/?t=NaN">0:10</a>'), 30);
  expect(root.querySelectorAll("button")).toHaveLength(1);
  expect(root.querySelector("button")?.dataset.podcastTimecode).toBe("20");
  expect(root.querySelector("script")).toBeNull();
  expect(root.querySelector("p")?.getAttribute("onclick")).toBeNull();
  expect(root.querySelector('[href^="javascript:"]')).toBeNull();
});

it("normalizes safe card excerpts without scripts or literal entities", () => {
  expect(podcastNotesExcerpt('<p>First &amp; Second.</p><p>Third&nbsp; Line.</p><script>bad()</script>')).toBe("First & Second. Third Line.");
  expect(podcastNotesExcerpt("<p>&#999999999999;</p>")).toBe("&#999999999999;");
});
