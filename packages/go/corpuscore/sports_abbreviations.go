package corpuscore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"sync"
)

// Reviewed display codes mirror the canonical Swift identity-keyed catalog.
var abbreviationCatalog = sync.OnceValue(buildReviewedAbbreviations)

func reviewedAbbreviations() map[string]string { return abbreviationCatalog() }
func buildReviewedAbbreviations() map[string]string {
	result := map[string]string{
		sportscore.ReviewedID("team:nfl:Arizona Cardinals"):     "ARZ",
		sportscore.ReviewedID("team:nfl:Atlanta Falcons"):       "ATL",
		sportscore.ReviewedID("team:nfl:Baltimore Ravens"):      "BLT",
		sportscore.ReviewedID("team:nfl:Buffalo Bills"):         "BUF",
		sportscore.ReviewedID("team:nfl:Carolina Panthers"):     "CAR",
		sportscore.ReviewedID("team:nfl:Chicago Bears"):         "CHI",
		sportscore.ReviewedID("team:nfl:Cincinnati Bengals"):    "CIN",
		sportscore.ReviewedID("team:nfl:Cleveland Browns"):      "CLV",
		sportscore.ReviewedID("team:nfl:Dallas Cowboys"):        "DAL",
		sportscore.ReviewedID("team:nfl:Denver Broncos"):        "DEN",
		sportscore.ReviewedID("team:nfl:Detroit Lions"):         "DET",
		sportscore.ReviewedID("team:nfl:Green Bay Packers"):     "GB",
		sportscore.ReviewedID("team:nfl:Houston Texans"):        "HST",
		sportscore.ReviewedID("team:nfl:Indianapolis Colts"):    "IND",
		sportscore.ReviewedID("team:nfl:Jacksonville Jaguars"):  "JAX",
		sportscore.ReviewedID("team:nfl:Kansas City Chiefs"):    "KC",
		sportscore.ReviewedID("team:nfl:Las Vegas Raiders"):     "LV",
		sportscore.ReviewedID("team:nfl:Los Angeles Chargers"):  "LAC",
		sportscore.ReviewedID("team:nfl:Los Angeles Rams"):      "LAR",
		sportscore.ReviewedID("team:nfl:Miami Dolphins"):        "MIA",
		sportscore.ReviewedID("team:nfl:Minnesota Vikings"):     "MIN",
		sportscore.ReviewedID("team:nfl:New England Patriots"):  "NE",
		sportscore.ReviewedID("team:nfl:New Orleans Saints"):    "NO",
		sportscore.ReviewedID("team:nfl:New York Giants"):       "NYG",
		sportscore.ReviewedID("team:nfl:New York Jets"):         "NYJ",
		sportscore.ReviewedID("team:nfl:Philadelphia Eagles"):   "PHI",
		sportscore.ReviewedID("team:nfl:Pittsburgh Steelers"):   "PIT",
		sportscore.ReviewedID("team:nfl:San Francisco 49ers"):   "SF",
		sportscore.ReviewedID("team:nfl:Seattle Seahawks"):      "SEA",
		sportscore.ReviewedID("team:nfl:Tampa Bay Buccaneers"):  "TB",
		sportscore.ReviewedID("team:nfl:Tennessee Titans"):      "TEN",
		sportscore.ReviewedID("team:nfl:Washington Commanders"): "WAS",
		sportscore.ReviewedID("team:mlb:Athletics"):             "ATH",
		sportscore.ReviewedID("team:mlb:Pittsburgh Pirates"):    "PIT",
		sportscore.ReviewedID("team:mlb:San Diego Padres"):      "SD",
		sportscore.ReviewedID("team:mlb:Seattle Mariners"):      "SEA",
		sportscore.ReviewedID("team:mlb:San Francisco Giants"):  "SF",
		sportscore.ReviewedID("team:mlb:St. Louis Cardinals"):   "STL",
		sportscore.ReviewedID("team:mlb:Tampa Bay Rays"):        "TB",
		sportscore.ReviewedID("team:mlb:Texas Rangers"):         "TEX",
		sportscore.ReviewedID("team:mlb:Toronto Blue Jays"):     "TOR",
		sportscore.ReviewedID("team:mlb:Minnesota Twins"):       "MIN",
		sportscore.ReviewedID("team:mlb:Philadelphia Phillies"): "PHI",
		sportscore.ReviewedID("team:mlb:Atlanta Braves"):        "ATL",
		sportscore.ReviewedID("team:mlb:Chicago White Sox"):     "CWS",
		sportscore.ReviewedID("team:mlb:Miami Marlins"):         "MIA",
		sportscore.ReviewedID("team:mlb:New York Yankees"):      "NYY",
		sportscore.ReviewedID("team:mlb:Milwaukee Brewers"):     "MIL",
		sportscore.ReviewedID("team:mlb:Los Angeles Angels"):    "LAA",
		sportscore.ReviewedID("team:mlb:Arizona Diamondbacks"):  "AZ",
		sportscore.ReviewedID("team:mlb:Baltimore Orioles"):     "BAL",
		sportscore.ReviewedID("team:mlb:Boston Red Sox"):        "BOS",
		sportscore.ReviewedID("team:mlb:Chicago Cubs"):          "CHC",
		sportscore.ReviewedID("team:mlb:Cincinnati Reds"):       "CIN",
		sportscore.ReviewedID("team:mlb:Cleveland Guardians"):   "CLE",
		sportscore.ReviewedID("team:mlb:Colorado Rockies"):      "COL",
		sportscore.ReviewedID("team:mlb:Detroit Tigers"):        "DET",
		sportscore.ReviewedID("team:mlb:Houston Astros"):        "HOU",
		sportscore.ReviewedID("team:mlb:Kansas City Royals"):    "KC",
		sportscore.ReviewedID("team:mlb:Los Angeles Dodgers"):   "LAD",
		sportscore.ReviewedID("team:mlb:Washington Nationals"):  "WSH",
		sportscore.ReviewedID("team:mlb:New York Mets"):         "NYM",
		sportscore.ReviewedID("team:nhl:Philadelphia Flyers"):   "PHI",
		sportscore.ReviewedID("team:nhl:New Jersey Devils"):     "NJD",
	}
	schools := map[string]string{"UCLA": "UCLA", "UConn": "UConn", "LSU": "LSU", "USC": "USC", "Wisconsin": "WISC", "Ohio State": "OSU", "Florida State": "FSU", "North Carolina": "UNC"}
	for _, e := range sportscore.ReviewedEntities() {
		if e.Kind == "ncaa-team" && e.SchoolID != nil {
			for school, code := range schools {
				if *e.SchoolID == sportscore.ReviewedID("school:"+school) {
					result[e.ID] = code
				}
			}
		}
	}
	result[sportscore.ReviewedID("team:dci:blue-devils")] = "BD"
	result[sportscore.ReviewedID("team:dci:blue-knights")] = "BK"
	result[sportscore.ReviewedID("team:dci:boston-crusaders")] = "BAC"
	result[sportscore.ReviewedID("team:dci:santa-clara-vanguard")] = "SCV"
	result[sportscore.ReviewedID("team:dci:phantom-regiment")] = "PR"
	result[sportscore.ReviewedID("team:wgi:percussion:marching:united-percussion")] = "UPW"
	result[sportscore.ReviewedID("team:wgi:percussion:marching:united-percussion-2")] = "UP2"
	result[sportscore.ReviewedID("team:wgi:percussion:marching:rcc")] = "RCC"
	result[sportscore.ReviewedID("team:wgi:percussion:marching:blue-knights")] = "BKPE"
	return result
}
