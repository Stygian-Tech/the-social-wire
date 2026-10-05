import Foundation

/// Reviewed league display groups. They do not create new entity identities or broaden matching feeds.
enum SportsReviewedTeamGroups {
  // Review references: https://www.nfl.com/standings/division/2026/reg and https://www.nba.com/teams (2026-10-04).
  static let groups: [(String, String, [String])] = [
    ("NFL", "AFC · East", ["Buffalo Bills", "Miami Dolphins", "New England Patriots", "New York Jets"]),
    ("NFL", "AFC · North", ["Baltimore Ravens", "Cincinnati Bengals", "Cleveland Browns", "Pittsburgh Steelers"]),
    ("NFL", "AFC · South", ["Houston Texans", "Indianapolis Colts", "Jacksonville Jaguars", "Tennessee Titans"]),
    ("NFL", "AFC · West", ["Denver Broncos", "Kansas City Chiefs", "Las Vegas Raiders", "Los Angeles Chargers"]),
    ("NFL", "NFC · East", ["Dallas Cowboys", "New York Giants", "Philadelphia Eagles", "Washington Commanders"]),
    ("NFL", "NFC · North", ["Chicago Bears", "Detroit Lions", "Green Bay Packers", "Minnesota Vikings"]),
    ("NFL", "NFC · South", ["Atlanta Falcons", "Carolina Panthers", "New Orleans Saints", "Tampa Bay Buccaneers"]),
    ("NFL", "NFC · West", ["Arizona Cardinals", "Los Angeles Rams", "San Francisco 49ers", "Seattle Seahawks"]),
    ("NBA", "Eastern Conference · Atlantic", ["Boston Celtics", "Brooklyn Nets", "New York Knicks", "Philadelphia 76ers", "Toronto Raptors"]),
    ("NBA", "Eastern Conference · Central", ["Chicago Bulls", "Cleveland Cavaliers", "Detroit Pistons", "Indiana Pacers", "Milwaukee Bucks"]),
    ("NBA", "Eastern Conference · Southeast", ["Atlanta Hawks", "Charlotte Hornets", "Miami Heat", "Orlando Magic", "Washington Wizards"]),
    ("NBA", "Western Conference · Northwest", ["Denver Nuggets", "Minnesota Timberwolves", "Oklahoma City Thunder", "Portland Trail Blazers", "Utah Jazz"]),
    ("NBA", "Western Conference · Pacific", ["Golden State Warriors", "Los Angeles Clippers", "Los Angeles Lakers", "Phoenix Suns", "Sacramento Kings"]),
    ("NBA", "Western Conference · Southwest", ["Dallas Mavericks", "Houston Rockets", "Memphis Grizzlies", "New Orleans Pelicans", "San Antonio Spurs"]),
    // Official 2026 memberships: https://www.mlb.com/standings/2026 (reviewed 2026-10-04).
    ("MLB", "American League · East", ["Baltimore Orioles", "Boston Red Sox", "New York Yankees", "Tampa Bay Rays", "Toronto Blue Jays"]),
    ("MLB", "American League · Central", ["Chicago White Sox", "Cleveland Guardians", "Detroit Tigers", "Kansas City Royals", "Minnesota Twins"]),
    ("MLB", "American League · West", ["Athletics", "Houston Astros", "Los Angeles Angels", "Seattle Mariners", "Texas Rangers"]),
    ("MLB", "National League · East", ["Atlanta Braves", "Miami Marlins", "New York Mets", "Philadelphia Phillies", "Washington Nationals"]),
    ("MLB", "National League · Central", ["Chicago Cubs", "Cincinnati Reds", "Milwaukee Brewers", "Pittsburgh Pirates", "St. Louis Cardinals"]),
    ("MLB", "National League · West", ["Arizona Diamondbacks", "Colorado Rockies", "Los Angeles Dodgers", "San Diego Padres", "San Francisco Giants"]),
    // Official current-season divisions: https://www.nhl.com/standings/2026-01-24/division (reviewed 2026-10-04).
    ("NHL", "Eastern Conference · Atlantic", ["Boston Bruins", "Buffalo Sabres", "Detroit Red Wings", "Florida Panthers", "Montreal Canadiens", "Ottawa Senators", "Tampa Bay Lightning", "Toronto Maple Leafs"]),
    ("NHL", "Eastern Conference · Metropolitan", ["Carolina Hurricanes", "Columbus Blue Jackets", "New Jersey Devils", "New York Islanders", "New York Rangers", "Philadelphia Flyers", "Pittsburgh Penguins", "Washington Capitals"]),
    ("NHL", "Western Conference · Central", ["Chicago Blackhawks", "Colorado Avalanche", "Dallas Stars", "Minnesota Wild", "Nashville Predators", "St. Louis Blues", "Utah Mammoth", "Winnipeg Jets"]),
    ("NHL", "Western Conference · Pacific", ["Anaheim Ducks", "Calgary Flames", "Edmonton Oilers", "Los Angeles Kings", "San Jose Sharks", "Seattle Kraken", "Vancouver Canucks", "Vegas Golden Knights"]),
    // Official 2026 conference list: https://www.mlssoccer.com/about/competition-guidelines (reviewed 2026-10-04).
    // Existing New York Red Bulls identity is retained; official club now displays Red Bull New York (https://www.newyorkredbulls.com/).
    ("MLS", "Eastern Conference", ["Atlanta United FC", "CF Montreal", "Charlotte FC", "Chicago Fire FC", "FC Cincinnati", "Columbus Crew", "D.C. United", "Inter Miami CF", "Nashville SC", "New England Revolution", "New York City FC", "New York Red Bulls", "Orlando City SC", "Philadelphia Union", "Toronto FC"]),
    ("MLS", "Western Conference", ["Austin FC", "Colorado Rapids", "FC Dallas", "Houston Dynamo FC", "LA Galaxy", "Los Angeles FC", "Minnesota United FC", "Portland Timbers", "Real Salt Lake", "San Diego FC", "San Jose Earthquakes", "Seattle Sounders FC", "Sporting Kansas City", "St. Louis City SC", "Vancouver Whitecaps FC"])
  ]
  static func path(league: String?, team: String) -> [String] {
    guard let group = groups.first(where: { $0.0 == league && $0.2.contains(team) }) else { return [] }
    return group.1.components(separatedBy: " · ")
  }
}
