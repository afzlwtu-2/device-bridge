// Package protocol defines the backwards-compatible DeviceBridge JSON wire schema.
package protocol

import "time"

const Version = 1
const Service = "_devicebridge._tcp"

type Device struct {
	Version  int      `json:"version"`
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Features []string `json:"features"`
}
type Invitation struct {
	Version int       `json:"version"`
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Token   string    `json:"token"`
	Expires time.Time `json:"expires"`
}
type PairRequest struct {
	Token string `json:"token"`
	Name  string `json:"name"`
}
type PairStatus struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}
type Root struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Writable bool   `json:"writable"`
}
type Entry struct {
	Name     string    `json:"name"`
	Path     string    `json:"path"`
	Kind     string    `json:"kind"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
}
type Listing struct {
	Entries []Entry `json:"entries"`
	Next    string  `json:"next,omitempty"`
}
type ManifestEntry struct {
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	SHA256    string `json:"sha256"`
	Directory bool   `json:"directory"`
}
type Manifest struct {
	Version int             `json:"version"`
	Root    string          `json:"root"`
	Path    string          `json:"path"`
	Entries []ManifestEntry `json:"entries"`
	Bytes   int64           `json:"bytes"`
}
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
