package main

import (
	"encoding/json"
	"errors"
	"regexp"
	"strings"
)

type config struct {
	Repository     string `json:"repository"`
	Infrastructure string `json:"infrastructure"`
	Fallback       string `json:"fallback"`
}

var repositoryPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$`)

func (c config) validate() error {
	for _, repository := range []string{c.Repository, c.Infrastructure} {
		_, name, _ := strings.Cut(repository, "/")
		if !repositoryPattern.MatchString(repository) || name == "." || name == ".." {
			return errors.New("repository and infrastructure must be OWNER/REPOSITORY")
		}
	}
	if strings.EqualFold(c.Repository, c.Infrastructure) {
		return errors.New("application and infrastructure repositories must differ")
	}
	var label string
	var labels []string
	if json.Unmarshal([]byte(c.Fallback), &label) == nil {
		labels = []string{label}
	} else if json.Unmarshal([]byte(c.Fallback), &labels) != nil {
		return errors.New("fallback must be a JSON label string or array")
	}
	if len(labels) == 0 {
		return errors.New("fallback must contain at least one label")
	}
	for _, label := range labels {
		if strings.TrimSpace(label) != label || label == "" || len(label) > 255 || strings.EqualFold(label, "yieldd") || strings.ContainsAny(label, "\x00\r\n") {
			return errors.New("fallback labels must be nonempty and cannot target yieldd")
		}
	}
	return nil
}
