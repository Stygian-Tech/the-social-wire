package podcastcore

type Person struct {
	Name     string  `json:"name"`
	Role     *string `json:"role,omitempty"`
	ImageURL *string `json:"imageUrl,omitempty"`
	URL      *string `json:"url,omitempty"`
}

func (v *Person) UnmarshalJSON(data []byte) error {
	type plain Person
	var decoded plain
	if err := decodeRequired(data, &decoded, "name"); err != nil {
		return err
	}
	*v = Person(decoded)
	return nil
}
