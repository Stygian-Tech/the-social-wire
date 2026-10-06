package wirecore

import (
	"net/url"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

type CommercialAssessment struct {
	Score          float64         `json:"score"`
	Classification CommercialClass `json:"classification"`
	Reasons        []string        `json:"reasons"`
}
type ContentEvidence struct {
	CanonicalURL                                  string
	Title, Summary, SourceText                    string
	TopicKeys                                     []string
	HasProductOfferSchema, HasAffiliateDisclosure bool
}

func TargetKindForURL(raw string, standardSite bool) TargetKind {
	trimmed := strings.TrimSpace(raw)
	lower := strings.ToLower(trimmed)
	if strings.HasPrefix(lower, "at://") {
		if strings.Contains(lower, "/app.bsky.feed.post/") {
			return SocialPost
		}
		return Unsupported
	}
	u, err := url.Parse(trimmed)
	if err != nil || u.Hostname() == "" {
		return Unsupported
	}
	host, path := strings.ToLower(u.Hostname()), strings.ToLower(u.Path)
	if host == "bsky.app" || strings.HasSuffix(host, ".bsky.app") {
		if regexp.MustCompile(`^/profile/[^/]+/post/[^/]+/?$`).MatchString(path) {
			return SocialPost
		}
		return ProfileOrFeed
	}
	first, _, _ := strings.Cut(host, ".")
	if first == "status" || first == "statuspage" || matchesDomain(host, []string{"statuspage.io", "status.io", "instatus.com", "betteruptime.com", "statuspal.io", "statuscast.com", "fedilist.com"}) {
		return OperationalStatus
	}
	if standardSite {
		return StandardSiteDocument
	}
	return ExternalArticle
}
func matchesDomain(host string, domains []string) bool {
	for _, d := range domains {
		if host == d || strings.HasSuffix(host, "."+d) {
			return true
		}
	}
	return false
}
func containsAny(text string, needles []string) bool {
	for _, n := range needles {
		if strings.Contains(text, n) {
			return true
		}
	}
	return false
}
func AssessCommercial(e ContentEvidence) CommercialAssessment {
	text := strings.ToLower(strings.Join(append([]string{e.Title, e.Summary, e.SourceText}, e.TopicKeys...), " "))
	reasons := []string{}
	score := 0.0
	add := func(reason string, value float64) { reasons = append(reasons, reason); score += value }
	// RE2 has no lookbehind; consuming the surrounding boundaries is equivalent
	// here because the classifier only asks whether any disclosure exists.
	if e.HasAffiliateDisclosure || containsAny(text, []string{"paid partnership", "sponsored post", "affiliate link"}) || regexp.MustCompile(`(^|[^a-z0-9])#(ad|sponsored)($|[^a-z0-9])`).MatchString(text) {
		add("explicit_ad_disclosure", 4)
	}
	if containsAny(text, []string{"buy now", "shop now", "order today", "use code", "promo code", "book a demo", "register now", "limited-time offer", "limited time offer", "subscribe and save", "free trial", "tag a friend", "follow and repost"}) {
		add("purchase_cta", 2)
	}
	if regexp.MustCompile(`([$€£]\s?\d|\d+%\s+off)`).MatchString(text) {
		add("price_or_discount", 1)
	}
	if containsAny(text, []string{"whatsapp", "telegram", "dm to order", "contact us at"}) {
		add("contact_solicitation", 1)
	}
	if e.HasProductOfferSchema || containsAny(text, []string{`"@type":"product"`, `"@type":"offer"`, "pricecurrency", "availability"}) {
		add("product_offer_schema", 3)
	}
	if u, err := url.Parse(e.CanonicalURL); err == nil {
		names := map[string]bool{}
		for _, part := range strings.Split(u.RawQuery, "&") {
			n, _, _ := strings.Cut(part, "=")
			if decoded, err := url.PathUnescape(n); err == nil {
				names[strings.ToLower(decoded)] = true
			}
		}
		for _, n := range []string{"affiliate", "aff", "ref", "referrer", "coupon", "promo"} {
			if names[n] {
				add("affiliate_parameter", 2)
				break
			}
		}
		for n := range names {
			if strings.HasPrefix(n, "utm_") || n == "gclid" || n == "fbclid" || n == "dclid" || n == "msclkid" {
				add("tracking_parameters", .25)
				break
			}
		}
		// Foundation removes one additional percent-encoding layer from .path.
		path, err := url.PathUnescape(u.Path)
		if err != nil {
			path = ""
		}
		segments := strings.Split(strings.ToLower(path), "/")
		referral, commercial := false, false
		for _, segment := range segments {
			if segment == "ref" || segment == "invite" || segment == "aff" || segment == "affiliate" {
				referral = true
			}
			if segment == "partner-content" || segment == "brand-studio" {
				commercial = true
			}
			for _, token := range strings.FieldsFunc(segment, func(r rune) bool { return r == '-' || r == '_' || r == '.' }) {
				if containsExact([]string{"sponsored", "advertorial", "deals", "offers", "shop", "shopping", "store", "product", "giveaway"}, token) {
					commercial = true
				}
			}
		}
		if referral {
			add("referral_path", 2)
		}
		if commercial {
			add("commercial_slug", 1)
		}
	}
	sort.Strings(reasons)
	class := Normal
	if score > 5 {
		class = ProbableAd
	} else if score >= 3 {
		class = Limited
	}
	return CommercialAssessment{score, class, reasons}
}
func containsExact(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}

const BaseContentLabelSource = "app.thesocialwire.base-content-labeler"

func IsExplicitAdultContent(e ContentEvidence) bool {
	host := ""
	if u, err := url.Parse(e.CanonicalURL); err == nil {
		host = strings.ToLower(u.Hostname())
	}
	if matchesDomain(host, []string{"3movs.com", "3dporndude.com", "mengem.com"}) {
		return true
	}
	text := strings.ToLower(strings.Join(append([]string{e.Title, e.Summary, e.SourceText}, e.TopicKeys...), " "))
	tokens := map[string]bool{}
	for _, s := range strings.FieldsFunc(text, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }) {
		tokens[s] = true
	}
	count := func(values []string) int {
		n := 0
		for _, v := range values {
			if tokens[v] {
				n++
			}
		}
		return n
	}
	if count([]string{"blowjob", "blowjobs", "cumshot", "cumshots", "deepthroat", "gangbang", "gangbangs", "hardcoreporn", "hentai", "pornographic"}) > 0 {
		return true
	}
	corroborating := []string{"bdsm", "cock", "cocks", "fuck", "fucking", "gagged", "hardcore", "milf", "naked", "pussy", "pussies", "stepsis", "stepbrother"}
	if count(corroborating) >= 2 {
		return true
	}
	anatomy := count([]string{"cock", "cocks", "dick", "dicks", "pussy", "pussies", "tit", "tits"})
	if anatomy >= 2 || anatomy > 0 && count([]string{"daddy", "dominating", "fetish", "hardcore", "horny", "porno", "porn", "steamy"}) >= 2 {
		return true
	}
	return matchesDomain(host, []string{"donmai.us"}) && count(append(corroborating, "breast", "breasts", "boob", "boobs", "groin", "nude")) > 0
}
