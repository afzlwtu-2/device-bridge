package files

import (
	"devicebridge/internal/filesproviders"
	"errors"
	"path"
	"sort"
	"strings"
)

// Exclusions are exact paths relative to the selected transfer root. A selected
// directory excludes its entire subtree; no glob, shell or implicit Git rules.
func ValidateExclusions(values []string) ([]string, error) {
	if len(values) > 256 {
		return nil, errors.New("too many exclusions")
	}
	result := make([]string, 0, len(values))
	seen := map[string]bool{}
	size := 0
	for _, value := range values {
		size += len(value)
		if size > 8192 || value == "" || value == "." || path.Clean(value) != value || filesproviders.ValidPath(value) != nil {
			return nil, errors.New("invalid transfer exclusion")
		}
		if !seen[value] {
			result = append(result, value)
			seen[value] = true
		}
	}
	sort.Strings(result)
	return result, nil
}
func Excluded(relative string, excludes []string) bool {
	for _, excluded := range excludes {
		if relative == excluded || strings.HasPrefix(relative, excluded+"/") {
			return true
		}
	}
	return false
}
