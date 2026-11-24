package main

import (
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"strings"

	"github.com/google/uuid"
)

type config struct {
	EC2            ec2Config `json:"ec2,omitzero"`
	Repository     string    `json:"repository"`
	Infrastructure string    `json:"infrastructure"`
	Fallback       string    `json:"fallback"`
	DeviceID       string    `json:"device_id,omitempty"`
	Platform       string    `json:"platform,omitempty"`
	LocalOnly      bool      `json:"local_only,omitempty"`
}

func (c config) platform() string {
	if c.Platform == "macos" {
		return "macos"
	}
	return "linux"
}

func (c config) scaleSetName() string {
	if c.platform() == "macos" {
		return "yieldd-macos"
	}
	return "yieldd"
}

var repositoryPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$`)

func (c config) validate() error {
	if c.Platform != "" && c.Platform != "macos" {
		return errors.New("invalid coordinator platform")
	}
	if c.DeviceID != "" {
		id, err := uuid.Parse(c.DeviceID)
		if err != nil || id.String() != c.DeviceID {
			return errors.New("device-id must be a lowercase UUID")
		}
	}
	for _, repository := range []string{c.Repository, c.Infrastructure} {
		_, name, _ := strings.Cut(repository, "/")
		if !repositoryPattern.MatchString(repository) || name == "." || name == ".." {
			return errors.New("repository and infrastructure must be OWNER/REPOSITORY")
		}
	}
	if strings.EqualFold(c.Repository, c.Infrastructure) && !c.LocalOnly {
		return errors.New("application and infrastructure repositories must differ")
	}
	if c.LocalOnly {
		if c.DeviceID == "" || c.Fallback != "" {
			return errors.New("local-only queues require a device and cannot configure a fallback")
		}
		return nil
	}
	labels, err := fallbackLabels(c.Fallback)
	if err != nil {
		return err
	}
	if len(labels) == 0 {
		return errors.New("fallback must contain at least one label")
	}
	for _, label := range labels {
		if strings.TrimSpace(label) != label || label == "" || len(label) > 255 || strings.EqualFold(label, "yieldd") || strings.EqualFold(label, "yieldd-linux") || strings.EqualFold(label, "yieldd-macos") || strings.ContainsAny(label, "\x00\r\n") {
			return errors.New("fallback labels must be nonempty and cannot target a yieldd scale set")
		}
	}
	return nil
}

func fallbackLabels(value string) ([]string, error) {
	var label string
	var labels []string
	if json.Unmarshal([]byte(value), &label) == nil {
		labels = []string{label}
	} else if json.Unmarshal([]byte(value), &labels) != nil {
		return nil, errors.New("fallback must be a JSON label string or array")
	}
	return labels, nil
}

func (c config) sameRoute(other config) bool {
	if c == other {
		return true
	}
	raw := c.Fallback
	c.Fallback = other.Fallback
	if c != other || c.LocalOnly {
		return false
	}
	left, err := fallbackLabels(raw)
	if err != nil {
		return false
	}
	right, err := fallbackLabels(other.Fallback)
	return err == nil && slices.Equal(left, right)
}
