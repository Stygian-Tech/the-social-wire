import { expect, it } from "bun:test";
import { displaySportsEntityName, displaySportsFeedTitle, displaySportsGroupPath } from "@/lib/sportsDisplayNames";
import { sportsFeedPickerGroups } from "@/lib/sportsFeedPickerGroups";
import type { SportsFeedDefinition } from "@/lib/sportsFeedClient";

it("uses US and Canadian terminology with an unqualified locale fallback", () => {
  for (const locale of ["en-US", "en-CA", "fr-CA", "en_US", "en", "invalid_locale!"]) {
    expect(displaySportsEntityName({kind:"sport",name:"Football"}, locale)).toBe("Soccer");
    expect(displaySportsEntityName({kind:"sport",name:"American Football"}, locale)).toBe("Football");
  }
});
it("uses Football and American Football for Britain and other explicit regions", () => {
  for (const locale of ["en-GB", "fr-FR", "es-ES", "en-IN", "en-GB-u-rg-uszzzz"]) {
    expect(displaySportsEntityName({kind:"sport",name:"Football"}, locale)).toBe("Football");
    expect(displaySportsEntityName({kind:"sport",name:"American Football"}, locale)).toBe("American\u00a0Football");
  }
});
it("keeps American Football unambiguous where football has other local meanings", () => {
  for (const locale of ["en-AU", "en-NZ", "en-IE", "en-ZA"]) {
    expect(displaySportsEntityName({kind:"sport",name:"Football"}, locale)).toBe("Soccer");
    expect(displaySportsEntityName({kind:"sport",name:"American Football"}, locale)).toBe("American\u00a0Football");
  }
});
it("preserves proper team and competition names and disambiguates NCAA paths", () => {
  expect(displaySportsEntityName({kind:"ncaa-team",name:"Mount Union Football"}, "en-US")).toBe("Mount Union Football");
  expect(displaySportsFeedTitle({kind:"competition",title:"SEC Football"}, "en-GB")).toBe("SEC\u00a0Football");
  expect(displaySportsGroupPath(["NCAA", "Division III", "Football", "Ohio Athletic Conference"], "en-GB")).toEqual(["NCAA", "Division III", "American Football", "Ohio Athletic Conference"]);
  expect(displaySportsGroupPath(["Teams", "Football", "Premier League"], "en-US")).toEqual(["Teams", "Soccer", "Premier League"]);
});
it("searches canonical and localized terms while preserving feeds and group identity", () => {
  const soccer: SportsFeedDefinition = {id:"soccer",title:"Football",kind:"sport",entityIDs:["association"],description:"Stories matching Football"};
  const american: SportsFeedDefinition = {id:"american",title:"American Football",kind:"sport",entityIDs:["gridiron"],description:"Stories matching American Football"};
  const team: SportsFeedDefinition = {id:"club",title:"Arsenal",kind:"team",entityIDs:["arsenal"],description:"Matching stories",groupPath:["Teams","Football","Premier League"]};
  expect(sportsFeedPickerGroups([soccer, american, team], "sports", "soccer", "en-US").flatMap(g=>g.feeds)).toEqual([soccer, team]);
  expect(sportsFeedPickerGroups([soccer, american], "sports", "American Football", "en-US").flatMap(g=>g.feeds)).toEqual([american]);
  const us = sportsFeedPickerGroups([team], "sports", "", "en-US")[0]!;
  const gb = sportsFeedPickerGroups([team], "sports", "", "en-GB")[0]!;
  expect(us.id).toBe(gb.id);
  expect(us.label).toBe("Teams › Soccer › Premier League");
  expect(gb.label).toBe("Teams › Football › Premier League");
  expect(team.title).toBe("Arsenal");
});

it("keeps sport and competition names together without changing search aliases or catalog names", () => {const feed:SportsFeedDefinition={id:"f1",title:"Formula 1",kind:"competition",entityIDs:["f1"],description:"Stories matching Formula 1"};expect(displaySportsFeedTitle(feed)).toBe("Formula\u00a01");expect(displaySportsEntityName({name:"Winter Sports",kind:"sport"})).toBe("Winter\u00a0Sports");expect(sportsFeedPickerGroups([feed],"sports","formula 1").flatMap(group=>group.feeds)).toEqual([feed]);expect(feed.title).toBe("Formula 1");});
