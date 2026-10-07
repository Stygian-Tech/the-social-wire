package financecore

// TopicEvidence exposes the existing resolver's exact bounded evidence to serving feed filters.
func TopicEvidence(title, summary string) (text string, financeContext bool) {
	value := evidence(title, summary)
	return value.text, value.finance
}
