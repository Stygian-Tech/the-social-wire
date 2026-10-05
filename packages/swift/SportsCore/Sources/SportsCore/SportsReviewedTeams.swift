public enum SportsReviewedTeams {
  public static var entities: [SportsEntity] {
    var result: [SportsEntity] = []
    for name in "Arizona Cardinals|Atlanta Falcons|Baltimore Ravens|Buffalo Bills|Carolina Panthers|Chicago Bears|Cincinnati Bengals|Cleveland Browns|Dallas Cowboys|Denver Broncos|Detroit Lions|Green Bay Packers|Houston Texans|Indianapolis Colts|Jacksonville Jaguars|Kansas City Chiefs|Las Vegas Raiders|Los Angeles Chargers|Los Angeles Rams|Miami Dolphins|Minnesota Vikings|New England Patriots|New Orleans Saints|New York Giants|New York Jets|Philadelphia Eagles|Pittsburgh Steelers|San Francisco 49ers|Seattle Seahawks|Tampa Bay Buccaneers|Tennessee Titans|Washington Commanders".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:nfl:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:american-football"), competitionIDs: [SportsReviewedCatalog.id("competition:nfl")], aliases: [String(name.split(separator: " ").last ?? name)]))
    }
    for name in "Atlanta Hawks|Boston Celtics|Brooklyn Nets|Charlotte Hornets|Chicago Bulls|Cleveland Cavaliers|Dallas Mavericks|Denver Nuggets|Detroit Pistons|Golden State Warriors|Houston Rockets|Indiana Pacers|Los Angeles Clippers|Los Angeles Lakers|Memphis Grizzlies|Miami Heat|Milwaukee Bucks|Minnesota Timberwolves|New Orleans Pelicans|New York Knicks|Oklahoma City Thunder|Orlando Magic|Philadelphia 76ers|Phoenix Suns|Portland Trail Blazers|Sacramento Kings|San Antonio Spurs|Toronto Raptors|Utah Jazz|Washington Wizards".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:nba:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:basketball"), competitionIDs: [SportsReviewedCatalog.id("competition:nba")], aliases: [String(name.split(separator: " ").last ?? name)]))
    }
    for name in "Atlanta Dream|Chicago Sky|Connecticut Sun|Dallas Wings|Golden State Valkyries|Indiana Fever|Las Vegas Aces|Los Angeles Sparks|Minnesota Lynx|New York Liberty|Phoenix Mercury|Seattle Storm|Washington Mystics|Toronto Tempo|Portland Fire".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:wnba:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:basketball"), competitionIDs: [SportsReviewedCatalog.id("competition:wnba")], aliases: [String(name.split(separator: " ").last ?? name)]))
    }
    for name in "Arizona Diamondbacks|Atlanta Braves|Baltimore Orioles|Boston Red Sox|Chicago Cubs|Chicago White Sox|Cincinnati Reds|Cleveland Guardians|Colorado Rockies|Detroit Tigers|Houston Astros|Kansas City Royals|Los Angeles Angels|Los Angeles Dodgers|Miami Marlins|Milwaukee Brewers|Minnesota Twins|New York Mets|New York Yankees|Athletics|Philadelphia Phillies|Pittsburgh Pirates|San Diego Padres|San Francisco Giants|Seattle Mariners|St. Louis Cardinals|Tampa Bay Rays|Texas Rangers|Toronto Blue Jays|Washington Nationals".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:mlb:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:baseball"), competitionIDs: [SportsReviewedCatalog.id("competition:mlb")], aliases: [String(name.split(separator: " ").last ?? name)]))
    }
    for name in "Anaheim Ducks|Boston Bruins|Buffalo Sabres|Calgary Flames|Carolina Hurricanes|Chicago Blackhawks|Colorado Avalanche|Columbus Blue Jackets|Dallas Stars|Detroit Red Wings|Edmonton Oilers|Florida Panthers|Los Angeles Kings|Minnesota Wild|Montreal Canadiens|Nashville Predators|New Jersey Devils|New York Islanders|New York Rangers|Ottawa Senators|Philadelphia Flyers|Pittsburgh Penguins|San Jose Sharks|Seattle Kraken|St. Louis Blues|Tampa Bay Lightning|Toronto Maple Leafs|Utah Mammoth|Vancouver Canucks|Vegas Golden Knights|Washington Capitals|Winnipeg Jets".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:nhl:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:ice-hockey"), competitionIDs: [SportsReviewedCatalog.id("competition:nhl")], aliases: [String(name.split(separator: " ").last ?? name)]))
    }
    for name in "Arsenal|Aston Villa|Bournemouth|Brentford|Brighton and Hove Albion|Chelsea|Crystal Palace|Everton|Fulham|Leeds United|Liverpool|Manchester City|Manchester United|Newcastle United|Nottingham Forest|Sunderland|Tottenham Hotspur|West Ham United|Wolverhampton Wanderers".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:premier-league:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:football"), competitionIDs: [SportsReviewedCatalog.id("competition:premier-league")]))
    }
    for name in "Arsenal Women|Chelsea Women|Manchester City Women|Manchester United Women|Liverpool Women|Tottenham Hotspur Women".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:wsl:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:football"), competitionIDs: [SportsReviewedCatalog.id("competition:wsl")]))
    }
    for name in "Chennai Super Kings|Delhi Capitals|Gujarat Titans|Kolkata Knight Riders|Lucknow Super Giants|Mumbai Indians|Punjab Kings|Rajasthan Royals|Royal Challengers Bengaluru|Sunrisers Hyderabad".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:ipl:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:cricket"), competitionIDs: [SportsReviewedCatalog.id("competition:ipl")]))
    }
    // Sponsor-name references: https://www.formula1.com/en/teams/red-bull-racing
    // and https://www.formula1.com/en/teams/racing-bulls.
    // Reviewed 2026 F1 grid: https://www.formula1.com/en/teams (2026-10-04).
    for name in "McLaren Formula 1 Team|Mercedes Formula 1 Team|Scuderia Ferrari|Red Bull Racing|Aston Martin Formula 1 Team|Alpine Formula 1 Team|Williams Formula 1 Team|Haas Formula 1 Team|Audi Formula 1 Team|Cadillac Formula 1 Team|Racing Bulls".split(separator: "|") {
      let aliases: [String]
      switch name {
      case "Red Bull Racing": aliases = ["RBR", "Oracle Red Bull Racing"]
      case "Racing Bulls": aliases = ["Visa Cash App Racing Bulls", "Visa Cash App Racing Bulls Formula One Team", "VCARB"]
      default: aliases = []
      }
      result.append(.init(id: SportsReviewedCatalog.id("team:f1:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:motorsport"), competitionIDs: [SportsReviewedCatalog.id("competition:f1")], aliases: aliases))
    }
    for name in "Atlanta United FC|Austin FC|CF Montreal|Charlotte FC|Chicago Fire FC|FC Cincinnati|Colorado Rapids|Columbus Crew|FC Dallas|D.C. United|Houston Dynamo FC|Inter Miami CF|LA Galaxy|Los Angeles FC|Minnesota United FC|Nashville SC|New England Revolution|New York City FC|New York Red Bulls|Orlando City SC|Philadelphia Union|Portland Timbers|Real Salt Lake|San Diego FC|San Jose Earthquakes|Seattle Sounders FC|Sporting Kansas City|St. Louis City SC|Toronto FC|Vancouver Whitecaps FC".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:mls:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:football"), competitionIDs: [SportsReviewedCatalog.id("competition:mls")]))
    }
    for name in "Angel City FC|Bay FC|Boston Legacy FC|Chicago Stars FC|Denver Summit FC|Houston Dash|Kansas City Current|NJ/NY Gotham FC|North Carolina Courage|Orlando Pride|Portland Thorns FC|Racing Louisville FC|San Diego Wave FC|Seattle Reign FC|Utah Royals FC|Washington Spirit".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:nwsl:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:football"), competitionIDs: [SportsReviewedCatalog.id("competition:nwsl")]))
    }
    for name in "Real Madrid|FC Barcelona|Atletico Madrid|Athletic Club|Real Sociedad|Villarreal CF|Real Betis|Sevilla FC|Valencia CF".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:la-liga:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:football"), competitionIDs: [SportsReviewedCatalog.id("competition:la-liga")]))
    }
    for name in "Bayern Munich|Borussia Dortmund|Bayer Leverkusen|RB Leipzig|Eintracht Frankfurt|VfB Stuttgart|Borussia Monchengladbach".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:bundesliga:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:football"), competitionIDs: [SportsReviewedCatalog.id("competition:bundesliga")]))
    }
    for name in "Inter Milan|AC Milan|Juventus|Napoli|AS Roma|Lazio|Atalanta".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:serie-a:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:football"), competitionIDs: [SportsReviewedCatalog.id("competition:serie-a")]))
    }
    for name in "Paris Saint-Germain|Olympique Marseille|Olympique Lyonnais|AS Monaco|Lille OSC".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:ligue-1:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:football"), competitionIDs: [SportsReviewedCatalog.id("competition:ligue-1")]))
    }
    for name in "Brisbane Broncos|Canberra Raiders|Canterbury-Bankstown Bulldogs|Cronulla-Sutherland Sharks|Dolphins Rugby League|Gold Coast Titans|Manly Warringah Sea Eagles|Melbourne Storm|Newcastle Knights|New Zealand Warriors|North Queensland Cowboys|Parramatta Eels|Penrith Panthers|South Sydney Rabbitohs|St. George Illawarra Dragons|Sydney Roosters|Wests Tigers".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:nrl:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:rugby-league"), competitionIDs: [SportsReviewedCatalog.id("competition:nrl")]))
    }
    for name in "Adelaide Crows|Brisbane Lions|Carlton Blues|Collingwood Magpies|Essendon Bombers|Fremantle Dockers|Geelong Cats|Gold Coast Suns|Greater Western Sydney Giants|Hawthorn Hawks|Melbourne Demons|North Melbourne Kangaroos|Port Adelaide Power|Richmond Tigers|St Kilda Saints|Sydney Swans|West Coast Eagles|Western Bulldogs".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:afl:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:australian-football"), competitionIDs: [SportsReviewedCatalog.id("competition:afl")]))
    }
    for name in "Delhi Capitals Women|Gujarat Giants Women|Mumbai Indians Women|Royal Challengers Bengaluru Women|UP Warriorz".split(separator: "|") {
      result.append(.init(id: SportsReviewedCatalog.id("team:wpl:" + name), name: String(name), kind: "team", sportID: SportsReviewedCatalog.id("sport:cricket"), competitionIDs: [SportsReviewedCatalog.id("competition:wpl")]))
    }
    return result
  }
}
