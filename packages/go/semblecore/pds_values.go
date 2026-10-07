package semblecore

func validRef(m map[string]any) bool {
	return required(m, "uri", "string") && optionalStrings(m, "cid")
}

func validLink(m map[string]any) bool {
	if !validRef(object(m, "collection")) || !validRef(object(m, "card")) || !required(m, "addedBy", "string") || !optionalStrings(m, "addedAt") {
		return false
	}
	if m["originalCard"] != nil && !validRef(object(m, "originalCard")) {
		return false
	}
	return true
}

func validCard(m map[string]any) bool {
	if !required(m, "type", "string") || !optionalStrings(m, "createdAt") {
		return false
	}
	if m["parentCard"] != nil && !validRef(object(m, "parentCard")) {
		return false
	}
	if m["content"] != nil && !required(object(m, "content"), "text", "string") {
		return false
	}
	return true
}
