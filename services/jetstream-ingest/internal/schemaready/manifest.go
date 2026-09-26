package schemaready

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var versionPattern = regexp.MustCompile(`^[0-9]{14}$`)

// Manifest contains every required receipt, rather than just a maximum version:
// an interrupted or skipped older migration must also prevent startup.
func Manifest(directory string) ([]string, error) {
	files, err := filepath.Glob(filepath.Join(directory, "*.sql"))
	if err != nil {
		return nil, errors.New("cannot enumerate migration files")
	}
	versions := make([]string, 0, len(files))
	for _, file := range files {
		version, _, found := strings.Cut(filepath.Base(file), "_")
		if !found {
			return nil, errors.New("invalid migration filename")
		}
		versions = append(versions, version)
	}
	return validateVersions(versions)
}

func ReadManifest(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("cannot read packaged migration manifest")
	}
	return validateVersions(strings.Fields(string(data)))
}

func validateVersions(versions []string) ([]string, error) {
	if len(versions) == 0 {
		return nil, errors.New("migration manifest is empty")
	}
	sort.Strings(versions)
	for index, version := range versions {
		if !versionPattern.MatchString(version) || (index > 0 && versions[index-1] == version) {
			return nil, errors.New("migration manifest contains invalid or duplicate versions")
		}
	}
	return versions, nil
}
